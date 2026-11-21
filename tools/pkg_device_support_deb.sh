#!/bin/bash
set -euo pipefail
WS=/root/rmx3370-ubuntu
PKG_DIR="$WS/out/debs"
STAGE="$WS/out/pkg-bitra-device-support"
VER="${1:-0.1}"
mkdir -p "$PKG_DIR"
rm -rf "$STAGE"

mkdir -p \
  "$STAGE/DEBIAN" \
  "$STAGE/etc/flash-kernel" \
  "$STAGE/etc/dracut.conf.d" \
  "$STAGE/etc/initramfs-tools/conf.d" \
  "$STAGE/etc/kernel/postinst.d" \
  "$STAGE/etc/initramfs/post-update.d" \
  "$STAGE/etc/systemd/system" \
  "$STAGE/etc/systemd/sleep.conf.d" \
  "$STAGE/etc/systemd/logind.conf.d" \
  "$STAGE/etc/ssh/sshd_config.d" \
  "$STAGE/etc/chrony/conf.d" "$STAGE/etc/NetworkManager/conf.d" "$STAGE/etc/udev/rules.d" \
  "$STAGE/usr/lib/bitra" \
  "$STAGE/usr/sbin"

# 1. Disable Ubuntu flash-kernel
echo "none" > "$STAGE/etc/flash-kernel/machine"

# 2. dracut generic config (hostonly=no so chroot/cross builds never omit UFS/ext4/SMMU)
cat > "$STAGE/etc/dracut.conf.d/90-bitra.conf" << "DRACUT"
hostonly="no"
hostonly_cmdline="no"
filesystems+=" ext4 "
compress="gzip"
omit_dracutmodules+=" network network-legacy plymouth iscsi nfs mdraid lvm dmraid btrfs resume "
DRACUT

# 2b. Compact initramfs-tools config (must stay < 14 MiB so ramdisk does not collide with dtb_offset 0x01f00000)
cat > "$STAGE/etc/initramfs-tools/conf.d/10-bitra.conf" << "INITRAMFS"
MODULES=list
COMPRESS=gzip
INITRAMFS

# 3. Copy boot-image helper tools (no OEM blobs!)
cp "$WS/tools/inject_dtbo_sink.py" "$STAGE/usr/lib/bitra/inject_dtbo_sink.py"
cp "$WS/tools/avbtool.py" "$STAGE/usr/lib/bitra/avbtool.py"
chmod 755 "$STAGE/usr/lib/bitra/inject_dtbo_sink.py" "$STAGE/usr/lib/bitra/avbtool.py"

# 4. Boot image builder hook (chroot-safe, exits 0 if prerequisites missing)
cat > "$STAGE/usr/sbin/bitra-update-bootimg" << "UPD"
#!/bin/bash
set -euo pipefail
KREL="${1:-}"
[ -n "$KREL" ] || { KREL=$(ls -1 /boot/vmlinuz-*-bitra* 2>/dev/null | sort -V | tail -n1 | sed "s|.*/vmlinuz-||"); }
[ -n "$KREL" ] || { echo "[bitra-boot] No bitra kernel found; skipping."; exit 0; }

KERNEL="/boot/vmlinuz-$KREL"
DTB="/usr/lib/linux-image-$KREL/qcom/sm8250-realme-bitra.dtb"
INITRD="/boot/initrd.img-$KREL"
DTBO="/var/lib/bitra/stock/bitra_dtbo_0.dtbo"
OUTDIR="/var/lib/bitra/boot"

if [ ! -f "$KERNEL" ] || [ ! -f "$DTB" ] || [ ! -f "$INITRD" ]; then
  echo "[bitra-boot] Missing kernel/dtb/initrd for $KREL; skipping boot image generation."
  exit 0
fi

if [ ! -f "$DTBO" ]; then
  echo "[bitra-boot] Notice: $DTBO not imported yet; skipping boot image generation (run bitra-import-dtbo on device)."
  exit 0
fi

if ! command -v mkbootimg >/dev/null 2>&1 || ! command -v fdtoverlay >/dev/null 2>&1; then
  echo "[bitra-boot] Notice: mkbootimg or fdtoverlay missing; skipping boot image generation."
  exit 0
fi

RAMDISK_SZ=$(stat -c%s "$INITRD")
if [ "$RAMDISK_SZ" -gt 14680064 ]; then
  echo "[bitra-boot] ERROR: $INITRD ($RAMDISK_SZ bytes) exceeds 14 MiB limit (would overlap dtb_offset 0x01f00000)!" >&2
  exit 1
fi

mkdir -p "$OUTDIR"
SINK_DTB="$OUTDIR/sm8250-realme-bitra-$KREL.sink.dtb"
NEW_IMG="$OUTDIR/boot-$KREL.img"

python3 /usr/lib/bitra/inject_dtbo_sink.py --in-dtb "$DTB" --dtbo "$DTBO" --out-dtb "$SINK_DTB"

CMDLINE="root=LABEL=ubuntu-root rootwait rw noresume console=ttyMSM0,115200n8 console=tty0 printk.devkmsg=on softlockup_panic=1 hung_task_panic=1 oops=panic panic=15"
mkbootimg --header_version 2 \
  --kernel "$KERNEL" \
  --ramdisk "$INITRD" \
  --dtb "$SINK_DTB" \
  --cmdline "$CMDLINE" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --tags_offset 0x00000100 --dtb_offset 0x01f00000 --pagesize 4096 \
  --os_version 12.0.0 --os_patch_level 2022-09-05 \
  -o "$NEW_IMG"

python3 /usr/lib/bitra/avbtool.py add_hash_footer --image "$NEW_IMG" --partition_name boot --partition_size 100663296
[ -f "$OUTDIR/boot-current.img" ] && cp -f "$OUTDIR/boot-current.img" "$OUTDIR/boot-previous.img"
cp -f "$NEW_IMG" "$OUTDIR/boot-current.img"
echo "[bitra-boot] Built $OUTDIR/boot-current.img for $KREL (chroot/safe mode: not flashing partition automatically)."
UPD
chmod 755 "$STAGE/usr/sbin/bitra-update-bootimg"

cat > "$STAGE/etc/kernel/postinst.d/zz-bitra-boot" << "HOOK"
#!/bin/sh
set -e
KREL="$1"
if command -v dracut >/dev/null 2>&1; then
  dracut --force "/boot/initrd.img-$KREL" "$KREL" || true
fi
/usr/sbin/bitra-update-bootimg "$KREL" || true
exit 0
HOOK
chmod 755 "$STAGE/etc/kernel/postinst.d/zz-bitra-boot"

cat > "$STAGE/etc/initramfs/post-update.d/zz-bitra-boot" << "HOOK2"
#!/bin/sh
set -e
/usr/sbin/bitra-update-bootimg "$1" || true
exit 0
HOOK2
chmod 755 "$STAGE/etc/initramfs/post-update.d/zz-bitra-boot"

# 5. USB CDC-ECM gadget service (192.168.2.15/24 + dnsmasq DHCP on usb0)
cat > "$STAGE/usr/sbin/bitra-usb-gadget.sh" << "USB"
#!/bin/bash
set -euo pipefail
modprobe libcomposite 2>/dev/null || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config
G=/sys/kernel/config/usb_gadget/g1
if [ ! -d "$G" ]; then
  mkdir -p "$G"
  echo 0x1d6b > "$G/idVendor"
  echo 0x0104 > "$G/idProduct"
  echo 0x0100 > "$G/bcdDevice"
  echo 0x0200 > "$G/bcdUSB"
  mkdir -p "$G/strings/0x409"
  echo "rmx3370-ubuntu" > "$G/strings/0x409/serialnumber"
  echo "realme" > "$G/strings/0x409/manufacturer"
  echo "RMX3370 Ubuntu Server" > "$G/strings/0x409/product"
  mkdir -p "$G/configs/c.1/strings/0x409"
  echo "ecm" > "$G/configs/c.1/strings/0x409/configuration"
  echo 500 > "$G/configs/c.1/MaxPower"
  mkdir -p "$G/functions/ecm.usb0"
  echo "02:11:22:33:44:55" > "$G/functions/ecm.usb0/dev_addr"
  echo "02:11:22:33:44:66" > "$G/functions/ecm.usb0/host_addr"
  ln -sf "$G/functions/ecm.usb0" "$G/configs/c.1/"
fi

UDC=""
for _ in $(seq 1 30); do
  UDC=$(ls /sys/class/udc 2>/dev/null | head -n1 || true)
  [ -n "$UDC" ] && break
  sleep 0.5
done
[ -n "$UDC" ] || { echo "[bitra-usb] No UDC available after 15s"; exit 0; }
CUR=$(cat "$G/UDC" 2>/dev/null || true)
[ -n "$CUR" ] || echo "$UDC" > "$G/UDC"

sleep 1
IFACE=$(cat "$G/functions/ecm.usb0/ifname" 2>/dev/null || echo usb0)
ip link set "$IFACE" up
ip addr replace 192.168.2.15/24 dev "$IFACE"

if command -v dnsmasq >/dev/null 2>&1; then
  pkill -f "dnsmasq.*bitra-usb" 2>/dev/null || true
  dnsmasq --interface="$IFACE" --bind-interfaces --port=0 \
    --dhcp-range=192.168.2.20,192.168.2.30,255.255.255.0,12h \
    --dhcp-option=3 --dhcp-option=6 \
    --dhcp-leasefile=/run/bitra-usb-dhcp.leases \
    --pid-file=/run/bitra-usb-dnsmasq.pid
fi
USB
chmod 755 "$STAGE/usr/sbin/bitra-usb-gadget.sh"

cat > "$STAGE/etc/systemd/system/bitra-usb-gadget.service" << "UNIT"
[Unit]
Description=RMX3370 USB CDC-ECM Debug & Management Network (192.168.2.15/24)
After=systemd-udevd.service local-fs.target
Wants=network-pre.target
Before=network.target ssh.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/bitra-usb-gadget.sh

[Install]
WantedBy=multi-user.target
UNIT

# 6. Key-only SSH (USB + Wi-Fi enabled, password auth disabled)
cat > "$STAGE/etc/ssh/sshd_config.d/10-bitra-keyonly.conf" << "SSH"
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
SSH

# 7. Headless 24/7 server power/sleep policy (no auto-suspend, power key safe)
cat > "$STAGE/etc/systemd/sleep.conf.d/10-bitra-server.conf" << "SLEEP"
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
SLEEP

cat > "$STAGE/etc/systemd/logind.conf.d/10-bitra-server.conf" << "LOGIND"
[Login]
HandlePowerKey=ignore
IdleAction=ignore
LOGIND

# 7b. Keep NetworkManager off USB CDC-ECM management interface
cat > "$STAGE/etc/NetworkManager/conf.d/10-bitra-unmanaged-usb0.conf" << "NM"
[keyfile]
unmanaged-devices=interface-name:usb0
NM

# 8. Allow chrony to step clock from 1970 RTC on boot
cat > "$STAGE/etc/chrony/conf.d/10-bitra-rtc.conf" << "CHRONY"
makestep 1.0 -1
CHRONY

# 9. Persistent deterministic Wi-Fi MAC when QCA6390 reports 00:00:00:00:00:00
cat > "$STAGE/usr/sbin/bitra-wifi-mac.sh" << "WMAC"
#!/bin/bash
set -euo pipefail
IFACE="${1:-wlp1s0}"
CUR=$(cat "/sys/class/net/$IFACE/address" 2>/dev/null || true)
[ "$CUR" = "00:00:00:00:00:00" ] || exit 0
if [ -s /var/lib/bitra/wlan_mac ]; then
  MAC=$(head -n1 /var/lib/bitra/wlan_mac | tr -d "[:space:]")
else
  SEED=$(cat /etc/machine-id 2>/dev/null || echo "bitra")
  HASH=$(printf "%s-wlan0" "$SEED" | sha256sum | cut -c1-10)
  MAC="02:${HASH:0:2}:${HASH:2:2}:${HASH:4:2}:${HASH:6:2}:${HASH:8:2}"
fi
ip link set dev "$IFACE" address "$MAC" || true
WMAC
chmod 755 "$STAGE/usr/sbin/bitra-wifi-mac.sh"

cat > "$STAGE/etc/udev/rules.d/99-bitra-wifi-mac.rules" << "WRULE"
ACTION=="add|move", SUBSYSTEM=="net", KERNEL=="wl*", RUN+="/usr/sbin/bitra-wifi-mac.sh %k"
WRULE

# 10. 24/7 anti-swelling 2S battery charge-limit controller (MP2650 + BQ28Z610)
cat > "$STAGE/etc/bitra-charge-limit.conf" << "CLCONF"
# 24/7 headless server battery anti-swelling thresholds (%)
# - SOC >= DRAIN_ABOVE_PCT -> force-discharge (drains safely down toward HIGH_PCT)
# - HIGH_PCT <= SOC < DRAIN_ABOVE_PCT -> inhibit-charge (USB bypass: powers system, 0 mA battery charge)
# - SOC <= LOW_PCT -> auto (recharges gently back up to HIGH_PCT)
# - SOC < 20 or unreadable -> ALWAYS auto (fail-safe)
ENABLED=1
LOW_PCT=55
HIGH_PCT=75
DRAIN_ABOVE_PCT=80
CLCONF

cat > "$STAGE/usr/sbin/bitra-charge-limit.sh" << "CLSH"
#!/bin/bash
set -euo pipefail
[ -f /etc/bitra-charge-limit.conf ] && . /etc/bitra-charge-limit.conf
[ "${ENABLED:-1}" = "1" ] || exit 0

BATT=/sys/class/power_supply/bq28z610-0/capacity
CHG=/sys/class/power_supply/mp2650-charger/charge_behaviour
[ -r "$BATT" ] && [ -w "$CHG" ] || exit 0

# Never alter charge_behaviour while sourcing 5V USB Host/OTG VBUS
if [ "$(cat /sys/class/usb_role/a600000.usb-role-switch/role 2>/dev/null || true)" = "host" ]; then
  exit 0
fi

SOC=$(cat "$BATT" 2>/dev/null || echo 0)
CUR=$(tr ' ' '\n' < "$CHG" 2>/dev/null | grep '^\[' | tr -d '[]' || echo auto)
LOW="${LOW_PCT:-55}"
HIGH="${HIGH_PCT:-75}"
DRAIN="${DRAIN_ABOVE_PCT:-80}"

TARGET="$CUR"
if ! [[ "$SOC" =~ ^[0-9]+$ ]] || [ "$SOC" -lt 20 ]; then
  TARGET="auto"
elif [ "$SOC" -ge "$DRAIN" ]; then
  TARGET="force-discharge"
elif [ "$SOC" -ge "$HIGH" ]; then
  TARGET="inhibit-charge"
elif [ "$SOC" -le "$LOW" ]; then
  TARGET="auto"
elif [ "$CUR" = "force-discharge" ]; then
  TARGET="inhibit-charge"
fi

if [ "$TARGET" != "$CUR" ]; then
  echo "$TARGET" > "$CHG"
  logger -t bitra-charge-limit "SOC=${SOC}% mode ${CUR} -> ${TARGET}"
fi
CLSH
chmod 755 "$STAGE/usr/sbin/bitra-charge-limit.sh"

cat > "$STAGE/etc/systemd/system/bitra-charge-limit.service" << "CLSVC"
[Unit]
Description=RMX3370 24/7 Anti-Swelling Charge Limit Control (MP2650 + BQ28Z610)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/bitra-charge-limit.sh
CLSVC

cat > "$STAGE/etc/systemd/system/bitra-charge-limit.timer" << "CLTMR"
[Unit]
Description=Run RMX3370 24/7 Anti-Swelling Charge Limit every 60s

[Timer]
OnBootSec=15s
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
CLTMR

cat > "$STAGE/DEBIAN/control" << CTRL
Package: bitra-device-support
Version: $VER
Architecture: arm64
Maintainer: ut-bitra <ut-bitra@localhost>
Section: admin
Priority: optional
Depends: bash, iproute2, python3
Recommends: dracut, dnsmasq-base, chrony, fake-hwclock, openssh-server
Description: Device integration layer for realme GT Neo 2 (RMX3370 / bitra)
 Provides flash-kernel disable, dracut config, boot image update hook,
 USB CDC-ECM management network, key-only SSH defaults, and 24/7 server policies.
CTRL

cat > "$STAGE/DEBIAN/postinst" << "POST"
#!/bin/sh
set -e
if [ -d /etc/systemd/system/multi-user.target.wants ]; then
  ln -sf /etc/systemd/system/bitra-usb-gadget.service /etc/systemd/system/multi-user.target.wants/bitra-usb-gadget.service
  mkdir -p /etc/systemd/system/timers.target.wants
  ln -sf /etc/systemd/system/bitra-charge-limit.timer /etc/systemd/system/timers.target.wants/bitra-charge-limit.timer
fi
exit 0
POST
chmod 755 "$STAGE/DEBIAN/postinst"

DEB="$PKG_DIR/bitra-device-support_${VER}_arm64.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB"
ls -lh "$DEB"
