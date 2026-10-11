#!/bin/bash
# ============================================================================
# RealKing 内核 + KernelSU-Next 非交互构建脚本
#
# 与作者 build_kernel.sh 的差别：
#   1) 不交互，参数由命令行/环境变量给出，便于 CI（GitHub Actions）调用
#   2) 自动 clone/更新 KernelSU-Next 到指定引用（默认 legacy 分支最新提交）
#   3) 产物写进 OUT_DIR，且不会像 build_kernel.sh 那样在源码目录执行 rm *.zip
#      （作者脚本每轮打包会删掉上一轮生成的 zip）
#   4) 额外生成 build-info-<设备>-<变体>.txt，记录内核/KernelSU-Next 的版本信息
#
# 用法:
#   scripts/build-kernelsu-next.sh [设备] [变体]
#     设备: alioth(默认) | apollo
#     变体: aosp(默认) | hyperos
#
# 常用环境变量:
#   KSU_REF=legacy        要检出的 KernelSU-Next 引用（分支/tag/commit）
#   KSU_REPO=...          KernelSU-Next 仓库地址
#   KSU_DIR=<内核目录>/KernelSU-Next
#   CLANG_DIR=<内核目录>/../clang   含 bin/clang 的工具链目录
#   OUT_DIR=<内核目录>/dist
#   JOBS=10               make 并行度（默认 nproc --all）
#   KSU_VERSION_OVERRIDE  覆盖内核内嵌的 KSU 版本号（传给 Kbuild）
#   SKIP_KSU_SYNC=1       不 clone/fetch KernelSU-Next
#   LOG_TO_STDOUT=1       构建日志同时打印到标准输出（CI 用）
# ============================================================================
set -euo pipefail

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
fi

KERNEL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DEVICE=${1:-alioth}
ROM=${2:-aosp}

case "$DEVICE" in
  alioth)
    KERNEL_DEFCONFIG=alioth_defconfig
    DEVICE_NAME1=alioth
    DEVICE_NAME2=aliothin
    IS_SLOT_DEVICE=1
    PANEL_DTSI="arch/arm64/boot/dts/vendor/qcom/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi"
    REMOVE_VENDOR_BOOT=0
    ;;
  apollo)
    KERNEL_DEFCONFIG=apollo_defconfig
    DEVICE_NAME1=apollo
    DEVICE_NAME2=apollon
    IS_SLOT_DEVICE=0
    PANEL_DTSI="arch/arm64/boot/dts/vendor/qcom/dsi-panel-j3s-37-02-0a-dsc-video.dtsi"
    REMOVE_VENDOR_BOOT=1
    ;;
  *)
    echo "未知设备 '$DEVICE'，可选: alioth, apollo" >&2
    exit 2
    ;;
esac

case "$(printf '%s' "$ROM" | tr 'A-Z' 'a-z')" in
  aosp)    TYPE=Aosp ;;
  hyperos) TYPE=HyperOs ;;
  *) echo "未知变体 '$ROM'，可选: aosp, hyperos" >&2; exit 2 ;;
esac

KSU_REPO=${KSU_REPO:-https://github.com/KernelSU-Next/KernelSU-Next.git}
KSU_BRANCH=${KSU_BRANCH:-legacy}
# KSU_REF 留空 = 取 KSU_BRANCH 上最新的 tag（作者已发布的版本，经过其审阅/发布流程）；
# 也可显式指定：KSU_REF=legacy（分支最新提交，可能尚未打 tag）、KSU_REF=v3.4.0-legacy、KSU_REF=<sha>
KSU_REF=${KSU_REF:-}
KSU_DIR=${KSU_DIR:-$KERNEL_DIR/KernelSU-Next}
CLANG_DIR=${CLANG_DIR:-$(dirname "$KERNEL_DIR")/clang}
OUT_DIR=${OUT_DIR:-$KERNEL_DIR/dist}
JOBS=${JOBS:-$(nproc --all 2>/dev/null || echo 4)}
LOG=$OUT_DIR/build-$DEVICE-$TYPE.log
BUILD_START=$(date '+%Y-%m-%d %H:%M:%S %z')

mkdir -p "$OUT_DIR"

CLANG_BIN=$CLANG_DIR/bin/clang
if [ ! -x "$CLANG_BIN" ]; then
  echo "错误: 找不到 clang: $CLANG_BIN" >&2
  echo "请设置 CLANG_DIR 指向含 bin/clang 的工具链目录（作者脚本约定为 <内核目录>/../clang）" >&2
  exit 3
fi

# ---- KernelSU-Next 源码同步 ----
if [ "${SKIP_KSU_SYNC:-0}" != "1" ]; then
  if [ ! -d "$KSU_DIR/.git" ]; then
    echo ">> 克隆 KernelSU-Next: $KSU_REPO -> $KSU_DIR"
    git clone "$KSU_REPO" "$KSU_DIR"
  fi
  git -C "$KSU_DIR" fetch --tags --prune origin
  if [ -n "$KSU_REF" ]; then
    if git -C "$KSU_DIR" rev-parse --verify --quiet "origin/$KSU_REF^{commit}" >/dev/null 2>&1; then
      TARGET="origin/$KSU_REF"
    else
      TARGET="$KSU_REF"
    fi
    echo ">> 更新 KernelSU-Next: KSU_REF=$KSU_REF -> $TARGET"
  else
    BASE="origin/$KSU_BRANCH"
    if ! git -C "$KSU_DIR" rev-parse --verify --quiet "$BASE^{commit}" >/dev/null 2>&1; then
      echo "错误: KernelSU-Next 里没有 $BASE（可用 KSU_BRANCH 指定其它分支）" >&2
      exit 5
    fi
    TARGET=$(git -C "$KSU_DIR" describe --tags --abbrev=0 "$BASE" 2>/dev/null || true)
    if [ -z "$TARGET" ]; then
      echo "错误: $BASE 上没有任何 tag；要分支最新提交请显式指定 KSU_REF=$KSU_BRANCH" >&2
      exit 5
    fi
    echo ">> 更新 KernelSU-Next: $KSU_BRANCH 上最新的 tag -> $TARGET（要分支最新提交请设 KSU_REF=$KSU_BRANCH）"
  fi
  git -C "$KSU_DIR" checkout --detach "$TARGET" >/dev/null 2>&1 || git -C "$KSU_DIR" checkout "$TARGET"
fi

if [ ! -e "$KERNEL_DIR/drivers/kernelsu/Kbuild" ]; then
  echo "错误: drivers/kernelsu 未接入（符号链接悬空？），请先运行 scripts/setup-kernelsu-next.sh" >&2
  exit 4
fi

# ---- 版本信息 ----
KSU_SHA=$(git -C "$KSU_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
KSU_SHORT=$(git -C "$KSU_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
KSU_COMMIT_DATE=$(git -C "$KSU_DIR" show -s --format=%cI HEAD 2>/dev/null || echo unknown)
KSU_COUNT=$(git -C "$KSU_DIR" rev-list --count HEAD 2>/dev/null || echo 0)
KSU_TAG=$(git -C "$KSU_DIR" describe --tags --abbrev=0 2>/dev/null || echo v0.0.1)
KSU_DESC=$(git -C "$KSU_DIR" describe --tags 2>/dev/null || echo "$KSU_TAG")
KSU_VERSION=$((30000 + KSU_COUNT + 289))
KSU_TAG_SHA=$(git -C "$KSU_DIR" rev-parse --verify --quiet "$KSU_TAG^{commit}" 2>/dev/null || echo "")
if [ -n "$KSU_TAG_SHA" ] && [ "$KSU_TAG_SHA" = "$KSU_SHA" ]; then KSU_TAG_EXACT=yes; else KSU_TAG_EXACT=no; fi
KSU_COMMITS_SINCE_TAG=$(git -C "$KSU_DIR" rev-list --count "$KSU_TAG..HEAD" 2>/dev/null || echo unknown)

KERNEL_SHA=$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
KERNEL_SHORT=$(git -C "$KERNEL_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
KERNEL_BRANCH=$(git -C "$KERNEL_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
KERNEL_SUBJECT=$(git -C "$KERNEL_DIR" show -s --format=%s HEAD 2>/dev/null || echo unknown)
KERNEL_COMMIT_DATE=$(git -C "$KERNEL_DIR" show -s --format=%cI HEAD 2>/dev/null || echo unknown)
KERNEL_REPO=$(git -C "$KERNEL_DIR" remote get-url origin 2>/dev/null || echo unknown)
LOCALVERSION=$(sed -n 's/^CONFIG_LOCALVERSION="\(.*\)"$/\1/p' "$KERNEL_DIR/arch/arm64/configs/$KERNEL_DEFCONFIG" | head -n1)
LOCALVERSION_SLUG=$(printf '%s' "${LOCALVERSION:-unknown}" | sed -e 's|~RealKing//||' -e 's|[^A-Za-z0-9._-]|-|g')

export ARCH=arm64
export SUBARCH=arm64
export PATH="$CLANG_DIR/bin:$PATH"
CLANG_VERSION=$("$CLANG_BIN" --version | head -n1)
export KBUILD_COMPILER_STRING=$("$CLANG_BIN" --version | head -n1 | perl -pe 's/\(http.*?\)//gs' | sed -e 's/  */ /g' -e 's/[[:space:]]*$//')

PANEL_W_OLD=70; PANEL_W_NEW=700; PANEL_H_OLD=155; PANEL_H_NEW=1540

# 还原被 KernelSU-Next Kbuild 就地 sed 修改的内核源码（构建前已快照内容）
restore_ksu_tree() {
  if [ -z "${KSU_SNAP_DIR:-}" ] || [ ! -d "${KSU_SNAP_DIR:-}" ]; then return 0; fi
  for _f in ${KSU_PATCH_PATHS:-}; do
    if [ -f "$KSU_SNAP_DIR/$_f" ] && ! cmp -s "$KSU_SNAP_DIR/$_f" "$KERNEL_DIR/$_f"; then
      cp -p "$KSU_SNAP_DIR/$_f" "$KERNEL_DIR/$_f" 2>/dev/null || true
    fi
  done
  return 0
}

restore_all() {
  cd "$KERNEL_DIR" 2>/dev/null || true
  if [ -f "$KERNEL_DIR/anykernel/anykernel.sh.bak" ]; then
    mv -f "$KERNEL_DIR/anykernel/anykernel.sh.bak" "$KERNEL_DIR/anykernel/anykernel.sh" || true
  fi
  if [ "$TYPE" = "HyperOs" ]; then
    sed -i "s/qcom,mdss-pan-physical-width-dimension = <$PANEL_W_NEW>;$/qcom,mdss-pan-physical-width-dimension = <$PANEL_W_OLD>;/" "$KERNEL_DIR/$PANEL_DTSI" || true
    sed -i "s/qcom,mdss-pan-physical-height-dimension = <$PANEL_H_NEW>;$/qcom,mdss-pan-physical-height-dimension = <$PANEL_H_OLD>;/" "$KERNEL_DIR/$PANEL_DTSI" || true
  fi
  restore_ksu_tree
  if [ -n "${KSU_SNAP_DIR:-}" ] && [ -d "${KSU_SNAP_DIR:-}" ]; then rm -rf "$KSU_SNAP_DIR"; fi
  rm -rf "$KERNEL_DIR/tmp" 2>/dev/null || true
}
trap restore_all EXIT

cd "$KERNEL_DIR"

# ---- HyperOS 变体：改面板物理尺寸（与作者脚本完全一致的 sed）----
if [ "$TYPE" = "HyperOs" ]; then
  echo ">> HyperOS 变体：面板尺寸 $PANEL_W_OLD->$PANEL_W_NEW / $PANEL_H_OLD->$PANEL_H_NEW（$PANEL_DTSI）"
  sed -i "s/qcom,mdss-pan-physical-width-dimension = <$PANEL_W_OLD>;$/qcom,mdss-pan-physical-width-dimension = <$PANEL_W_NEW>;/" "$PANEL_DTSI"
  sed -i "s/qcom,mdss-pan-physical-height-dimension = <$PANEL_H_OLD>;$/qcom,mdss-pan-physical-height-dimension = <$PANEL_H_NEW>;/" "$PANEL_DTSI"
fi
PANEL_WIDTH=$(sed -n 's/.*qcom,mdss-pan-physical-width-dimension = <\([0-9]*\)>;.*/\1/p' "$PANEL_DTSI" | head -n1)
PANEL_HEIGHT=$(sed -n 's/.*qcom,mdss-pan-physical-height-dimension = <\([0-9]*\)>;.*/\1/p' "$PANEL_DTSI" | head -n1)

# ---- anykernel.sh 设备适配 ----
cp -p anykernel/anykernel.sh anykernel/anykernel.sh.bak
sed -i "s/device.name1=.*/device.name1=$DEVICE_NAME1/" anykernel/anykernel.sh
sed -i "s/device.name2=.*/device.name2=$DEVICE_NAME2/" anykernel/anykernel.sh
sed -i "s/is_slot_device=.*/is_slot_device=$IS_SLOT_DEVICE/" anykernel/anykernel.sh
if [ "$REMOVE_VENDOR_BOOT" = "1" ]; then
  sed -i '/## vendor_boot shell variables/,/## end vendor_boot install/d' anykernel/anykernel.sh
fi

# ---- 编译 ----
run_logged() {
  if [ "${LOG_TO_STDOUT:-0}" = "1" ]; then
    "$@" 2>&1 | tee -a "$LOG"
  else
    "$@" >>"$LOG" 2>&1
  fi
}

: > "$LOG"
echo ">> 编译 $DEVICE_NAME1 / $TYPE（KernelSU-Next $KSU_DESC / $KSU_VERSION），日志: $LOG"
if ! run_logged make "$KERNEL_DEFCONFIG" O=out CC=clang; then
  echo "错误: defconfig 失败，日志尾部:" >&2; tail -n 30 "$LOG" >&2; exit 5
fi
# ---- KernelSU-Next 的 Kbuild 会在 make 解析阶段用 sed 直接改内核源码，先做内容快照 ----
# 被改的文件从 Kbuild 里动态提取（形如 $(srctree)/fs/namespace.c），只保留确实存在的文件
KSU_PATCH_PATHS=$(grep -o '\$(srctree)/[^ ;)]*' "$KSU_DIR/kernel/Kbuild" 2>/dev/null \
  | sed 's|\$(srctree)/||' | sort -u | while read -r _f; do
      if [ -f "$KERNEL_DIR/$_f" ]; then printf '%s\n' "$_f"; fi
    done | tr '\n' ' ' || true)
if [ -z "$KSU_PATCH_PATHS" ]; then
  KSU_PATCH_PATHS="fs/namespace.c fs/internal.h include/linux/seccomp.h security/selinux/hooks.c"
fi
KSU_SNAP_DIR=$(mktemp -d)
for _f in $KSU_PATCH_PATHS; do
  mkdir -p "$KSU_SNAP_DIR/$(dirname "$_f")"
  cp -p "$KERNEL_DIR/$_f" "$KSU_SNAP_DIR/$_f" 2>/dev/null || true
done

if ! run_logged make -j"$JOBS" O=out CC=clang ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- NM=llvm-nm OBJDUMP=llvm-objdump STRIP=llvm-strip; then
  echo "错误: 编译失败，日志尾部:" >&2; tail -n 60 "$LOG" >&2; exit 6
fi

# ---- 以 Kbuild 自己算出的版本为准（$(info) 会打进日志）----
# ---- 构建期间被 KernelSU-Next Kbuild 就地修改的内核源码：记录后立刻还原 ----
KSU_TREE_PATCHED=""
for _f in ${KSU_PATCH_PATHS:-}; do
  if [ -f "$KSU_SNAP_DIR/$_f" ] && ! cmp -s "$KSU_SNAP_DIR/$_f" "$KERNEL_DIR/$_f"; then
    KSU_TREE_PATCHED="$KSU_TREE_PATCHED $_f"
  fi
done
KSU_TREE_PATCHED=$(printf '%s' "$KSU_TREE_PATCHED" | sed -e 's/^ *//')
if [ -n "$KSU_TREE_PATCHED" ]; then
  echo ">> KernelSU-Next 构建期改动了内核源码（已还原）: $KSU_TREE_PATCHED"
  restore_ksu_tree
fi

KSU_LOG_VERSION=$(grep -m1 -o -- '-- KernelSU-Next version: [0-9]*' "$LOG" | awk '{print $NF}' || true)
KSU_LOG_TAG=$(grep -m1 -o -- '-- KernelSU-Next tag: [^ ]*' "$LOG" | awk '{print $NF}' || true)
if [ -n "$KSU_LOG_VERSION" ]; then KSU_VERSION=$KSU_LOG_VERSION; fi
if [ -n "$KSU_LOG_TAG" ]; then KSU_TAG=$KSU_LOG_TAG; fi

# ---- 从编译产物里核对版本串 ----
IMAGE_KSU_TAG=not-found
IMAGE_KSU_BANNER=not-found
KERNEL_VERSION_STRING=unknown
IMAGE_RAW_SIZE=0
TMPIMG=$(mktemp)
if gzip -dc out/arch/arm64/boot/Image.gz > "$TMPIMG" 2>/dev/null; then
  IMAGE_RAW_SIZE=$(stat -c %s "$TMPIMG")
  TMPSTR=$(mktemp)
  # 注意：不能写 strings | grep -q，set -o pipefail 下 grep 提前退出会让 strings 收到 SIGPIPE（141），
  # 整个管道被判为失败，导致明明存在的字符串被报成 not-found。
  if command -v strings >/dev/null 2>&1 && strings -a "$TMPIMG" > "$TMPSTR" 2>/dev/null; then
    if grep -q -F -- "$KSU_TAG" "$TMPSTR"; then IMAGE_KSU_TAG=$KSU_TAG; fi
    IMAGE_KSU_BANNER=$(grep -m1 -o -- 'welcome to KernelSU version [0-9]*' "$TMPSTR" | head -n1 || true)
    KERNEL_VERSION_STRING=$(grep -m1 -o '^Linux version .*' "$TMPSTR" | head -n1 || true)
  fi
  [ -n "$IMAGE_KSU_BANNER" ] || IMAGE_KSU_BANNER=not-found
  [ -n "$KERNEL_VERSION_STRING" ] || KERNEL_VERSION_STRING=unknown
  rm -f "$TMPSTR"
fi
rm -f "$TMPIMG"

# ---- 打包（AnyKernel3 zip，与作者脚本一致）----
TIME=$(date '+%Y%m%d-%H%M%S')
ZIP_NAME="RealKing-$DEVICE_NAME1-$TYPE-$TIME-KSUNext-$KSU_VERSION.zip"
rm -rf tmp; mkdir -p tmp
cp -fp out/arch/arm64/boot/Image.gz out/arch/arm64/boot/dtbo.img out/arch/arm64/boot/dtb tmp/
cp -rp ./anykernel/* tmp/
SEVENZ=""
if command -v 7z >/dev/null 2>&1; then SEVENZ=7z; elif command -v 7za >/dev/null 2>&1; then SEVENZ=7za; fi
if [ -n "$SEVENZ" ]; then
  ( cd tmp && "$SEVENZ" a -mx9 tmp.zip * >/dev/null )
else
  ( cd tmp && zip -9 -r -q tmp.zip * )
fi
mv -f tmp/tmp.zip "$OUT_DIR/$ZIP_NAME"
rm -rf tmp
ZIP_SIZE=$(stat -c %s "$OUT_DIR/$ZIP_NAME")
ZIP_MD5=$(md5sum "$OUT_DIR/$ZIP_NAME" | awk '{print $1}')
ZIP_SHA256=$(sha256sum "$OUT_DIR/$ZIP_NAME" | awk '{print $1}')

# ---- 构建信息 ----
INFO="$OUT_DIR/build-info-$DEVICE-$TYPE.txt"
cat > "$INFO" <<EOF
KERNEL_NAME=RealKing
KERNEL_DEVICE=$DEVICE_NAME1
KERNEL_DEVICE_NAME2=$DEVICE_NAME2
VARIANT=$TYPE
KERNEL_REPO=$KERNEL_REPO
KERNEL_BRANCH=$KERNEL_BRANCH
KERNEL_COMMIT=$KERNEL_SHA
KERNEL_COMMIT_SHORT=$KERNEL_SHORT
KERNEL_COMMIT_DATE=$KERNEL_COMMIT_DATE
KERNEL_COMMIT_SUBJECT=$KERNEL_SUBJECT
KERNEL_DEFCONFIG=$KERNEL_DEFCONFIG
KERNEL_LOCALVERSION=$LOCALVERSION
KERNEL_LOCALVERSION_SLUG=$LOCALVERSION_SLUG
KERNEL_VERSION_STRING=$KERNEL_VERSION_STRING
KSU_REPO=$KSU_REPO
KSU_REF=$KSU_REF
KSU_COMMIT=$KSU_SHA
KSU_COMMIT_SHORT=$KSU_SHORT
KSU_COMMIT_DATE=$KSU_COMMIT_DATE
KSU_COMMIT_COUNT=$KSU_COUNT
KSU_TAG=$KSU_TAG
KSU_TAG_EXACT=$KSU_TAG_EXACT
KSU_COMMITS_SINCE_TAG=$KSU_COMMITS_SINCE_TAG
KSU_DESCRIBE=$KSU_DESC
KSU_BRANCH=$KSU_BRANCH
KSU_VERSION=$KSU_VERSION
KSU_VERSION_CODE=$KSU_VERSION
KSU_IMAGE_TAG_CHECK=$IMAGE_KSU_TAG
KSU_IMAGE_BANNER=$IMAGE_KSU_BANNER
KSU_TREE_PATCHED=$KSU_TREE_PATCHED
CLANG_VERSION=$CLANG_VERSION
PANEL_DIMENSIONS=${PANEL_WIDTH}x${PANEL_HEIGHT}
PANEL_DTSI=$PANEL_DTSI
BUILD_JOBS=$JOBS
BUILD_HOST=$(uname -n)
BUILD_TIME=$BUILD_START
BUILD_END=$(date '+%Y-%m-%d %H:%M:%S %z')
IMAGE_RAW_SIZE=$IMAGE_RAW_SIZE
ZIP_NAME=$ZIP_NAME
ZIP_SIZE=$ZIP_SIZE
ZIP_MD5=$ZIP_MD5
ZIP_SHA256=$ZIP_SHA256
EOF

echo ">> 完成: $OUT_DIR/$ZIP_NAME"
echo "   内核: $KERNEL_SHORT ($KERNEL_BRANCH)  变体: $TYPE"
echo "   KernelSU-Next: $KSU_DESC -> KSU_VERSION=$KSU_VERSION"
echo "   镜像内 KSU tag 核对: $IMAGE_KSU_TAG | 横幅: $IMAGE_KSU_BANNER"
echo "   大小: $ZIP_SIZE  md5: $ZIP_MD5"
echo "   信息文件: $INFO"
