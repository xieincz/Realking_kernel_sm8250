#!/bin/sh
# Fetch/refresh KernelSU-Next (legacy branch, non-GKI kprobe mode) and wire it
# into this kernel tree: clones ./KernelSU-Next, symlinks drivers/kernelsu,
# and patches drivers/Makefile + drivers/Kconfig. Idempotent.
set -eu
cd "$(dirname "$0")/.."
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy
