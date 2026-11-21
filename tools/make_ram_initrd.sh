#!/bin/bash
set -euo pipefail
WS=/root/rmx3370-ubuntu
STAGE="$WS/out/initramfs-ram-debug"
OUT_CPIO="$WS/out/initramfs-ram-debug.cpio.gz"
BUSYBOX=/root/ut-work/mainline-bitra/initramfs-debug/bin/busybox

[ -x "$BUSYBOX" ] || { echo "Missing static aarch64 busybox at $BUSYBOX" >&2; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE"/{bin,sbin,etc,proc,sys,dev,tmp,run,var/lib/misc,usr/bin,usr/sbin}
cp "$BUSYBOX" "$STAGE/bin/busybox"
chmod 755 "$STAGE/bin/busybox"

cat > "$STAGE/init" << "INITEOF"
#!/bin/busybox sh
/bin/busybox --install -s /bin 2>/dev/null
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /run /tmp /var/lib/misc
mount -t devpts devpts /dev/pts 2>/dev/null || true

# Safety: set all block devices read-only before doing anything else
for b in /dev/sd* /dev/mmcblk*; do
  [ -b "$b" ] && blockdev --setro "$b" 2>/dev/null || true
done

# Start USB CDC-ECM gadget on 192.168.2.15/24 (verified native on macOS AppleUSBECM)
mount -t configfs none /sys/kernel/config 2>/dev/null || true
G=/sys/kernel/config/usb_gadget/g1
mkdir -p "$G"
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
echo 0x0100 > "$G/bcdDevice"
echo 0x0200 > "$G/bcdUSB"
mkdir -p "$G/strings/0x409"
echo "rmx3370-mainline" > "$G/strings/0x409/serialnumber"
echo "realme" > "$G/strings/0x409/manufacturer"
echo "RMX3370 Mainline Debug" > "$G/strings/0x409/product"
mkdir -p "$G/configs/c.1/strings/0x409"
echo "ecm" > "$G/configs/c.1/strings/0x409/configuration"
echo 500 > "$G/configs/c.1/MaxPower"
mkdir -p "$G/functions/ecm.usb0"
echo "02:11:22:33:44:55" > "$G/functions/ecm.usb0/dev_addr"
echo "02:11:22:33:44:66" > "$G/functions/ecm.usb0/host_addr"
ln -sf "$G/functions/ecm.usb0" "$G/configs/c.1/"

# Wait up to 10s for UDC to appear
UDC=""
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  UDC=$(ls /sys/class/udc 2>/dev/null | head -n1 || true)
  [ -n "$UDC" ] && break
  usleep 500000 2>/dev/null || sleep 1
done

if [ -n "$UDC" ]; then
  echo "$UDC" > "$G/UDC"
  sleep 1
  IFACE=$(cat "$G/functions/ecm.usb0/ifname" 2>/dev/null || echo usb0)
  ip link set lo up 2>/dev/null || true
  ip link set "$IFACE" up 2>/dev/null || ifconfig "$IFACE" up 2>/dev/null || true
  ip addr add 192.168.2.15/24 dev "$IFACE" 2>/dev/null || ifconfig "$IFACE" 192.168.2.15 netmask 255.255.255.0 up 2>/dev/null || true
  cat > /etc/udhcpd.conf << DHCPEOF
start 192.168.2.20
end   192.168.2.30
interface $IFACE
lease_file /tmp/udhcpd.leases
opt subnet 255.255.255.0
opt router 192.168.2.15
opt lease 3600
DHCPEOF
  touch /tmp/udhcpd.leases
  udhcpd /etc/udhcpd.conf 2>/dev/null || true
  telnetd -l /bin/sh -p 23 2>/dev/null || true
  TIMEOUT=${RAM_TIMEOUT:-60}
else
  TIMEOUT=10
fi

i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  [ -f /tmp/keepalive ] && i=0 && rm -f /tmp/keepalive
  sleep 1
  i=$((i + 1))
done

reboot -f -n 2>/dev/null || echo b > /proc/sysrq-trigger
INITEOF
chmod 755 "$STAGE/init"

(cd "$STAGE" && find . | cpio -H newc -o --owner=0:0 2>/dev/null | gzip -9 > "$OUT_CPIO")
ls -lh "$OUT_CPIO"
