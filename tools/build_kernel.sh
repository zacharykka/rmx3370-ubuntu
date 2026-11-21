#!/bin/bash
set -euo pipefail
WS=/root/rmx3370-ubuntu
SRC="$WS/kernel"
OUT="${OUT:-$WS/out/ram-debug}"
mkdir -p "$OUT"

exec 9>"$OUT/.build.lock"
flock -n 9 || { echo "ERROR: another build holds $OUT/.build.lock" >&2; exit 1; }

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export KBUILD_BUILD_TIMESTAMP="2026-11-21 00:00:00 UTC"
export KBUILD_BUILD_USER="builder"
export KBUILD_BUILD_HOST="rmx3370-ubuntu"
export KCFLAGS="-ffile-prefix-map=$SRC=/linux -ffile-prefix-map=$OUT=/kbuild"
export KAFLAGS="-ffile-prefix-map=$SRC=/linux -ffile-prefix-map=$OUT=/kbuild"

CC_CMD="ccache aarch64-linux-gnu-gcc"
NPROC=$(nproc)

if [ "${1:-}" = "--defconfig" ]; then
  shift
  make -C "$SRC" O="$OUT" LOCALVERSION="" CC="$CC_CMD" defconfig
  scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" "$@" 2>/dev/null || \
    "$SRC/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" "$@"
  make -C "$SRC" O="$OUT" LOCALVERSION="" CC="$CC_CMD" olddefconfig
  exit 0
fi

TARGETS=("$@")
if [ ${#TARGETS[@]} -eq 0 ]; then
  TARGETS=(Image dtbs)
fi

ccache -z >/dev/null 2>&1 || true
T0=$(date +%s)
make -C "$SRC" O="$OUT" LOCALVERSION="" CC="$CC_CMD" -j"$NPROC" "${TARGETS[@]}"
T1=$(date +%s)
echo "=== BUILD DONE in $((T1 - T0))s ==="
ccache -s | head -n 12 || true
