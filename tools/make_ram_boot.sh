#!/bin/bash
set -euo pipefail
WS=/root/rmx3370-ubuntu
OUT="${OUT:-$WS/out/ram-debug}"
IMG="${1:-$WS/out/boot-bitra-mainline-ram.img}"
EXTRA_CMDLINE="${2:-}"

KERNEL="$OUT/arch/arm64/boot/Image"
RAW_DTB="$OUT/arch/arm64/boot/dts/qcom/sm8250-realme-bitra.dtb"
SINK_DTB="$OUT/sm8250-realme-bitra.sink.dtb"
DTBO="$WS/private/stock/bitra_dtbo_0.dtbo"
RAMDISK="$WS/out/initramfs-ram-debug.cpio.gz"

[ -f "$KERNEL" ] || { echo "Missing $KERNEL" >&2; exit 1; }
[ -f "$RAW_DTB" ] || { echo "Missing $RAW_DTB" >&2; exit 1; }
[ -f "$RAMDISK" ] || "$WS/tools/make_ram_initrd.sh"

# Mandatory gate 1: inject disabled /dtbo-sink & verify offline overlay with fdtoverlay
python3 "$WS/tools/inject_dtbo_sink.py" --in-dtb "$RAW_DTB" --dtbo "$DTBO" --out-dtb "$SINK_DTB"

# Mandatory gate 2: keep cmdline short (< 400 bytes) & include panic auto-recovery
CMDLINE="console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xa90000 printk.devkmsg=on softlockup_panic=1 hung_task_panic=1 oops=panic panic=15 $EXTRA_CMDLINE"
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

python3 "$WS/tools/avbtool.py" add_hash_footer --image "$IMG" --partition_name boot --partition_size 100663296
ls -lh "$IMG"
