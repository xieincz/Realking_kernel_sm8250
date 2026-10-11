#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 RealKing 内核 Release 说明（markdown）与 build-info.json。

读取 scripts/build-kernelsu-next.sh 产出的 build-info-*.txt（每个变体一份），
可选通过 GitHub API 获取 KernelSU-Next 最新管理器信息，渲染出：

  release-notes.md  发布说明（内核 commit / KernelSU-Next commit / 版本号 /
                    配套管理器 / 文件校验值 / 刷机与复现说明）
  build-info.json   同一份信息的机器可读版本

用法:
  scripts/gen-release-notes.py --artifacts dist [--container <容器 zip 名>] \\
      [--out dist/release-notes.md] [--json dist/build-info.json] \\
      [--manager-tag v3.4.1] [--manager-version 33333] \\
      [--manager-apk KernelSU_Next_v3.4.1_33333-release.apk] \\
      [--manager-apk-spoofed ...] [--manager-min-kernel 33188] \\
      [--ksu-dir ./KernelSU-Next] [--run-url URL] [--repo-url URL] [--extra-note FILE]
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import urllib.request

KSU_SLUG = "KernelSU-Next/KernelSU-Next"
KSU_HTML = "https://github.com/" + KSU_SLUG
NATIVES_PATH = "manager/app/src/main/java/com/rifsxd/ksunext/Natives.kt"
DEFAULT_MIN_KERNEL = "33188"


def parse_info_file(path):
    info = {}
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            info[key.strip()] = value.strip()
    return info


def file_hashes(path):
    md5 = hashlib.md5()
    sha256 = hashlib.sha256()
    size = 0
    with open(path, "rb") as fh:
        while True:
            chunk = fh.read(1 << 20)
            if not chunk:
                break
            size += len(chunk)
            md5.update(chunk)
            sha256.update(chunk)
    return size, md5.hexdigest(), sha256.hexdigest()


def human_size(n):
    return "%s 字节 (%.2f MiB)" % (format(n, ","), n / 1048576.0)


def api_json(url):
    req = urllib.request.Request(url, headers={
        "User-Agent": "realking-kernel-release-notes",
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def manager_from_api(tag=None):
    if tag:
        data = api_json("https://api.github.com/repos/%s/releases/tags/%s" % (KSU_SLUG, tag))
    else:
        data = api_json("https://api.github.com/repos/%s/releases/latest" % KSU_SLUG)
    names = [a.get("name", "") for a in data.get("assets", [])]
    apks = [n for n in names if n.endswith("-release.apk")]
    plain = next((n for n in apks if "spoofed" not in n), "")
    spoof = next((n for n in apks if "spoofed" in n), "")
    version = ""
    m = re.search(r"_(\d+)-release\.apk$", plain or spoof)
    if m:
        version = m.group(1)
    return {
        "tag": data.get("tag_name", tag or ""),
        "url": data.get("html_url", ""),
        "published_at": (data.get("published_at") or "")[:10],
        "apk": plain,
        "apk_spoofed": spoof,
        "version_code": version,
    }


def releases_list():
    """列出 KernelSU-Next 的 release（含每个 release 的管理器 versionCode）；失败返回 []。"""
    try:
        data = api_json("https://api.github.com/repos/%s/releases?per_page=30" % KSU_SLUG)
    except Exception:
        return []
    out = []
    for r in data if isinstance(data, list) else []:
        names = [a.get("name", "") for a in r.get("assets", [])]
        apks = [n for n in names if n.endswith("-release.apk")]
        plain = next((n for n in apks if "spoofed" not in n), "")
        spoof = next((n for n in apks if "spoofed" in n), "")
        m = re.search(r"_(\d+)-release\.apk$", plain or spoof)
        out.append({
            "tag": r.get("tag_name", ""),
            "url": r.get("html_url", ""),
            "published_at": (r.get("published_at") or "")[:10],
            "apk": plain,
            "apk_spoofed": spoof,
            "version_code": m.group(1) if m else "",
        })
    return out


def compat_str(min_k, ksu_version):
    try:
        return "✓ 满足最低要求" if int(ksu_version) >= int(min_k) else "⚠ 低于最低要求，请改用更旧的管理器"
    except ValueError:
        return "（无法比较）"


def manager_min_kernel(ksu_dir, tag):
    if not tag or not ksu_dir or not os.path.isdir(os.path.join(ksu_dir, ".git")):
        return ""
    try:
        out = subprocess.run(["git", "-C", ksu_dir, "show", "%s:%s" % (tag, NATIVES_PATH)],
                             capture_output=True, text=True, timeout=180)
    except Exception:
        return ""
    m = re.search(r"MINIMAL_SUPPORTED_KERNEL\s*=\s*(\d+)", out.stdout)
    return m.group(1) if m else ""


def render_markdown(infos, files, manager, min_kernel, args):
    p = infos[0]
    variants = "、".join(i.get("VARIANT", "?") for i in infos)
    ksu_version = p.get("KSU_VERSION", "?")
    min_k = min_kernel or DEFAULT_MIN_KERNEL
    compat = compat_str(min_k, ksu_version)
    repo_url = args.repo_url or p.get("KERNEL_REPO", "")
    lines = []
    add = lines.append

    add("# RealKing 内核 · %s · KernelSU-Next %s (%s)" % (p.get("KERNEL_DEVICE", "?"), p.get("KSU_TAG", "?"), ksu_version))
    add("")
    add("> 由 GitHub Actions 一键构建 · 变体：%s · 构建完成：%s" % (variants, p.get("BUILD_END", "?")))
    if args.run_url:
        add("> 构建日志：[Actions run](%s)" % args.run_url)
    add("")
    add("## 一、内核信息")
    add("")
    add("| 项 | 值 |")
    add("|---|---|")
    add("| 内核 | RealKing（Rohail33）· Linux 4.19.325 · sm8250 |")
    add("| 设备 | `%s`（`%s`） |" % (p.get("KERNEL_DEVICE", "?"), p.get("KERNEL_DEVICE_NAME2", "?")))
    add("| 仓库 / 分支 | %s · `%s` |" % (repo_url, p.get("KERNEL_BRANCH", "?")))
    add("| 提交 | `%s`（%s，%s） |" % (p.get("KERNEL_COMMIT_SHORT", "?"), p.get("KERNEL_COMMIT_SUBJECT", "?"), p.get("KERNEL_COMMIT_DATE", "?")))
    add("| 内核版本串 | `%s` |" % p.get("KERNEL_VERSION_STRING", "?"))
    add("| 编译工具链 | %s |" % p.get("CLANG_VERSION", "?"))
    add("")
    add("## 二、KernelSU-Next")
    add("")
    add("| 项 | 值 |")
    add("|---|---|")
    add("| 仓库 | %s |" % KSU_HTML)
    ref_disp = p.get("KSU_REF") or "（未指定 → 自动取该分支上最新 tag）"
    if p.get("KSU_TAG_EXACT") == "yes":
        tag_note = "，本次内核使用的提交**就是该 tag 本身**"
    elif p.get("KSU_COMMITS_SINCE_TAG") not in (None, "", "unknown"):
        tag_note = "，本次内核使用的提交在该 tag **之后第 %s 个提交**（非发布版）" % p["KSU_COMMITS_SINCE_TAG"]
    else:
        tag_note = ""
    add("| 分支 / 引用 | `KSU_BRANCH=%s` · `KSU_REF=%s` |" % (p.get("KSU_BRANCH", "legacy"), ref_disp))
    add("| 提交 | `%s`（%s） |" % (p.get("KSU_COMMIT_SHORT", "?"), p.get("KSU_COMMIT_DATE", "?")))
    add("| 基线 tag | `%s`（describe：`%s`%s） |" % (p.get("KSU_TAG", "?"), p.get("KSU_DESCRIBE", "?"), tag_note))
    add("| KSU 版本号 | **%s**（= 30000 + %s + 289） |" % (ksu_version, p.get("KSU_COMMIT_COUNT", "?")))
    tag_chk = p.get("KSU_IMAGE_TAG_CHECK", "?")
    tag_chk_disp = "未在镜像中找到 tag 字符串" if tag_chk == "not-found" else "镜像内含 tag 字符串 `%s`" % tag_chk
    banner = p.get("KSU_IMAGE_BANNER", "?")
    banner_disp = "无（该版本 KernelSU-Next 不打印运行期版本横幅）" if banner == "not-found" else "`%s`" % banner
    add("| 镜像内核对 | %s；横幅：%s |" % (tag_chk_disp, banner_disp))
    add("| hook 模式 | kprobe（`CONFIG_KSU_KPROBES_HOOK=y`，非 GKI 内核推荐） |")
    add("")
    add("### 配套管理器 APK")
    add("")
    exact = None
    for _r in releases_list():
        if str(_r.get("version_code", "")) == str(ksu_version):
            exact = _r
            break
    if exact:
        add("- **精确匹配（推荐）**：[%s](%s) 的 **`%s`**（versionCode `%s`，与内核 KSU 版本号完全一致）"
            % (exact.get("tag", "?"), exact.get("url", KSU_HTML),
               exact.get("apk") or exact.get("apk_spoofed") or "?", exact.get("version_code")))
        if exact.get("apk_spoofed"):
            add("- 精确匹配的去伪装包（应用包名不同，用于规避检测）：`%s`" % exact["apk_spoofed"])
        ex_min = manager_min_kernel(args.ksu_dir, exact.get("tag", "")) or min_k
        add("- 精确匹配版本的最低支持内核：`%s` → 本内核 `%s` %s" % (ex_min, ksu_version, compat_str(ex_min, ksu_version)))
    if manager.get("tag") and (not exact or manager.get("tag") != exact.get("tag")):
        add("- 最新 release：[%s](%s)%s" % (manager["tag"], manager.get("url", KSU_HTML),
                                          "（%s）" % manager["published_at"] if manager.get("published_at") else ""))
        add("- 最新 release 的 APK：**`%s`**（versionCode `%s`）" % (manager.get("apk", "?"), manager.get("version_code", "?")))
        if manager.get("apk_spoofed"):
            add("- 最新 release 的去伪装包：`%s`" % manager["apk_spoofed"])
        add("- 最新 release 的最低支持内核：`%s` → 本内核 `%s` %s" % (min_k, ksu_version, compat))
    if not exact and not manager.get("tag"):
        add("- 未取到 release 信息，请到 [KernelSU-Next Releases](%s/releases) 下载管理器 APK。" % KSU_HTML)
    add("")
    add("管理器的 versionCode 与内核的 KSU 版本号是同一套编号（例如内核 tag `v3.4.0-legacy` = %s，"
        "对应 release `v3.4.0` 的管理器 versionCode 33294）。安装 versionCode 不低于内核 KSU 版本所在代次、"
        "且 ≥ %s 的任一管理器即可。" % (p.get("KSU_VERSION", "?"), min_k))
    add("")
    add("## 三、产物文件")
    add("")
    add("| 文件 | 大小 | MD5 | SHA256 |")
    add("|---|---|---|---|")
    for f in files:
        add("| `%s` | %s | `%s` | `%s` |" % (f["name"], human_size(f["size"]), f["md5"], f["sha256"]))
    add("")
    if args.container:
        add("`%s` 是容器包，里面就是两个内层 zip（AOSP 与 HyperOS 变体），解压后任选其一刷入。" % args.container)
        add("")
    add("## 四、刷入与使用")
    add("")
    add("1. **先备份分区**：TWRP 里备份 `boot`、`dtbo`、`vendor_boot`、`vbmeta`（AnyKernel3 会写 boot 与 dtbo，"
        "并把 dtb 写进 vendor_boot，必要时还会改 vbmeta 标志）。")
    add("2. 选变体：**AOSP** 包用于类原生/AOSP 系统，**HyperOS** 包用于 HyperOS/MIUI 类系统。"
        "两个包的差别只在 `dtbo.img` 里面板节点 `qcom,mdss-pan-physical-width/height-dimension` 的取值"
        "（AOSP `70×155`、HyperOS `700×1540`），内核本体与设备树相同。")
    add("3. 在 TWRP 里直接刷对应的 AnyKernel3 zip（不要解压后单独刷 `Image.gz`）。")
    add("4. 开机后安装上面的管理器 APK，打开即为已 root；管理器里可查看内核 KSU 版本号是否为 `%s`。" % ksu_version)
    add("5. 若管理器提示内核版本过低/不兼容，说明管理器 versionCode 对应的最低要求高于本内核的 KSU 版本，"
        "换用更旧的 release APK（≥ %s）即可。" % min_k)
    add("")
    add("## 五、如何复现")
    add("")
    add("一键：仓库 **Actions → Build kernel (KernelSU-Next) → Run workflow**，"
        "设备选 `%s`，KernelSU-Next 引用留空（= 取 `%s` 分支上最新 tag，即本次使用的 `%s`），"
        "勾选发布 Release 即可。" % (p.get("KERNEL_DEVICE", "alioth"), p.get("KSU_BRANCH", "legacy"), p.get("KSU_TAG", "?")))
    add("")
    add("本地：")
    add("")
    add("```bash")
    add("git clone %s && cd %s" % (repo_url or "<仓库地址>", os.path.basename(repo_url.rstrip("/")) or "Realking_kernel_sm8250"))
    add("git checkout %s" % p.get("KERNEL_BRANCH", "alioth"))
    add("# clang 放在内核目录的同级：<父目录>/clang/bin/clang")
    _ref = p.get("KSU_REF", "")
    _ref_env = ("KSU_REF=%s " % _ref) if _ref else ""
    add("CLANG_DIR=$HOME/toolchains/weebx JOBS=10 %s./scripts/build-kernelsu-next.sh %s aosp"
        % (_ref_env, p.get("KERNEL_DEVICE", "alioth")))
    add("CLANG_DIR=$HOME/toolchains/weebx JOBS=10 %s./scripts/build-kernelsu-next.sh %s hyperos"
        % (_ref_env, p.get("KERNEL_DEVICE", "alioth")))
    add("```")
    add("")
    add("脚本默认取 `KSU_BRANCH`（默认 `legacy`）上**最新的 tag**（= 作者已发布的版本），"
        "也可用 `KSU_REF=legacy` 取分支最新提交，或直接指定 tag / commit SHA；随后自动接入 `drivers/kernelsu`，"
        "产物与 `build-info-*.txt` 一起写进 `dist/`。")
    add("")
    if args.extra_note and os.path.isfile(args.extra_note):
        add(open(args.extra_note, encoding="utf-8").read().rstrip())
        add("")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description="生成 RealKing 内核 Release 说明")
    ap.add_argument("--artifacts", required=True, help="含 build-info-*.txt 与 zip 的目录")
    ap.add_argument("--container", default="", help="容器 zip 文件名")
    ap.add_argument("--out", default="", help="markdown 输出路径（默认 <artifacts>/release-notes.md）")
    ap.add_argument("--json", dest="json_out", default="", help="JSON 输出路径（默认 <artifacts>/build-info.json）")
    ap.add_argument("--manager-tag", default="")
    ap.add_argument("--manager-version", default="")
    ap.add_argument("--manager-apk", default="")
    ap.add_argument("--manager-apk-spoofed", default="")
    ap.add_argument("--manager-min-kernel", default="")
    ap.add_argument("--ksu-dir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "KernelSU-Next"))
    ap.add_argument("--run-url", default="")
    ap.add_argument("--repo-url", default="")
    ap.add_argument("--extra-note", default="")
    args = ap.parse_args()

    info_paths = sorted(glob.glob(os.path.join(args.artifacts, "build-info-*.txt")))
    if not info_paths:
        sys.stderr.write("错误: %s 下没有 build-info-*.txt\n" % args.artifacts)
        return 2
    infos = [parse_info_file(p) for p in info_paths]

    files = []
    for path in sorted(glob.glob(os.path.join(args.artifacts, "*.zip"))):
        size, md5, sha256 = file_hashes(path)
        files.append({"name": os.path.basename(path), "size": size, "md5": md5, "sha256": sha256})

    manager = {"tag": args.manager_tag, "apk": args.manager_apk, "apk_spoofed": args.manager_apk_spoofed,
               "version_code": args.manager_version, "url": "", "published_at": ""}
    if not manager["apk"]:
        try:
            fetched = manager_from_api(args.manager_tag or None)
            for k, v in fetched.items():
                if not manager.get(k):
                    manager[k] = v
        except Exception as exc:  # 无网络时退化，不阻塞发布
            sys.stderr.write("警告: 查询 KernelSU-Next release 失败: %s\n" % exc)

    min_kernel = args.manager_min_kernel or manager_min_kernel(args.ksu_dir, manager.get("tag", ""))

    md = render_markdown(infos, files, manager, min_kernel, args)
    out_path = args.out or os.path.join(args.artifacts, "release-notes.md")
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(md)

    primary = infos[0]
    payload = {
        "generated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "container": args.container,
        "kernel": {
            "repo": args.repo_url or primary.get("KERNEL_REPO", ""),
            "branch": primary.get("KERNEL_BRANCH", ""),
            "commit": primary.get("KERNEL_COMMIT", ""),
            "commit_short": primary.get("KERNEL_COMMIT_SHORT", ""),
            "commit_date": primary.get("KERNEL_COMMIT_DATE", ""),
            "version_string": primary.get("KERNEL_VERSION_STRING", ""),
            "device": primary.get("KERNEL_DEVICE", ""),
            "clang": primary.get("CLANG_VERSION", ""),
        },
        "kernelsu_next": {
            "repo": KSU_HTML,
            "ref": primary.get("KSU_REF", ""),
            "commit": primary.get("KSU_COMMIT", ""),
            "commit_short": primary.get("KSU_COMMIT_SHORT", ""),
            "commit_date": primary.get("KSU_COMMIT_DATE", ""),
            "commit_count": primary.get("KSU_COMMIT_COUNT", ""),
            "tag": primary.get("KSU_TAG", ""),
            "describe": primary.get("KSU_DESCRIBE", ""),
            "version": primary.get("KSU_VERSION", ""),
            "hook_mode": "kprobe",
        },
        "manager": {
            "release_tag": manager.get("tag", ""),
            "release_url": manager.get("url", ""),
            "apk": manager.get("apk", ""),
            "apk_spoofed": manager.get("apk_spoofed", ""),
            "version_code": manager.get("version_code", ""),
            "min_supported_kernel": min_kernel or DEFAULT_MIN_KERNEL,
        },
        "variants": infos,
        "artifacts": files,
    }
    json_path = args.json_out or os.path.join(args.artifacts, "build-info.json")
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2, sort_keys=False)
        fh.write("\n")

    print("已生成: %s" % out_path)
    print("已生成: %s" % json_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
