#!/bin/bash
set -euo pipefail
WS=/root/rmx3370-ubuntu
OUT="${OUT:-$WS/out/server-build}"
KREL=$(make -s -C "$WS/kernel" O="$OUT" ARCH=arm64 LOCALVERSION="" CROSS_COMPILE="ccache aarch64-linux-gnu-" kernelrelease)
IMG="${1:-$WS/out/boot-bitra-ubuntu-${KREL}.img}"
EXTRA_CMDLINE="${2:-}"

KERNEL="$OUT/arch/arm64/boot/Image"
RAW_DTB="$OUT/arch/arm64/boot/dts/qcom/sm8250-realme-bitra.dtb"
SINK_DTB="$OUT/sm8250-realme-bitra.sink.dtb"
DTBO="$WS/private/stock/bitra_dtbo_0.dtbo"
RAMDISK="$WS/out/initrd.img-$KREL"

[ -f "$KERNEL" ] || { echo "Missing $KERNEL" >&2; exit 1; }
[ -f "$RAW_DTB" ] || { echo "Missing $RAW_DTB" >&2; exit 1; }
[ -f "$RAMDISK" ] || { echo "Missing $RAMDISK" >&2; exit 1; }

RAMDISK_SZ=$(stat -c%s "$RAMDISK")
echo "[ubuntu-boot] ramdisk size = $((RAMDISK_SZ / 1024)) KiB ($RAMDISK_SZ bytes) / 15360 KiB max gap (0x01000000..0x01f00000)"
if [ "$RAMDISK_SZ" -gt 14680064 ]; then
  echo "ERROR: ramdisk exceeds 14 MiB safe limit and would collide with dtb_offset (0x01f00000)!" >&2
  exit 1
fi

python3 "$WS/tools/inject_dtbo_sink.py" --in-dtb "$RAW_DTB" --dtbo "$DTBO" --out-dtb "$SINK_DTB"

CMDLINE="root=LABEL=ubuntu-root rootwait rw noresume console=ttyMSM0,115200n8 console=tty0 printk.devkmsg=on softlockup_panic=1 hung_task_panic=1 oops=panic panic=15 $EXTRA_CMDLINE"
if [ ${#CMDLINE} -gt 400 ]; then
  echo "ERROR: cmdline too long (${#CMDLINE} > 400)" >&2
  exit 1
fi

/usr/local/bin/mkbootimg --header_version 2 \
  --kernel "$KERNEL" \
  --ramdisk "$RAMDISK" \
  --dtb "$SINK_DTB" \
  --cmdline "$CMDLINE" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --tags_offset 0x00000100 --dtb_offset 0x01f00000 --pagesize 4096 \
  --os_version 12.0.0 --os_patch_level 2022-09-05 \
  -o "$IMG"

RAW_SZ=$(stat -c%s "$IMG")
echo "[ubuntu-boot] raw boot.img size = $((RAW_SZ / 1024 / 1024)) MiB ($RAW_SZ bytes) / 96 MiB limit"
if [ "$RAW_SZ" -gt 98000000 ]; then
  echo "ERROR: boot image exceeds safe margin in 96 MiB boot partition!" >&2
  exit 1
fi

python3 "$WS/tools/avbtool.py" add_hash_footer --image "$IMG" --partition_name boot --partition_size 100663296
ls -lh "$IMG"
sha256sum "$IMG"
