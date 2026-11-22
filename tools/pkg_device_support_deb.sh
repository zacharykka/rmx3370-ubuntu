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
  "$STAGE/etc/wireplumber/main.lua.d" \
  "$STAGE/etc/chrony/conf.d" "$STAGE/etc/NetworkManager/conf.d" "$STAGE/etc/udev/rules.d" "$STAGE/etc/default" \
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
  # 0xe0 = bus+self-powered + remote-wakeup capable (prevents dwc3 dropping DHCP/ARP on macOS USB suspend)
  echo 0xe0 > "$G/configs/c.1/bmAttributes"
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
  dnsmasq --interface="$IFACE" --bind-dynamic --port=0 --dhcp-authoritative \
    --dhcp-range=192.168.2.20,192.168.2.30,255.255.255.0,12h \
    --dhcp-option=3 --dhcp-option=6 \
    --dhcp-leasefile=/run/bitra-usb-dhcp.leases \
    --pid-file=/run/bitra-usb-dnsmasq.pid
fi

# pm8150b_typec (tcpm) does an initial ~1.2s PORT_RESET shortly after boot that can drop
# dwc3 out of device link while g1/UDC still looks bound. Recover once after tcpm settles
# (only when not in OTG host mode).
rebind_if_detached() {
  ROLE_NODE="/sys/class/usb_role/${UDC}-role-switch/role"
  STATE=$(cat "/sys/class/udc/$UDC/state" 2>/dev/null || true)
  ROLE=$(cat "$ROLE_NODE" 2>/dev/null || true)
  if [ "$STATE" != "configured" ] && [ "$ROLE" != "host" ]; then
    [ -w "$ROLE_NODE" ] && echo none > "$ROLE_NODE" 2>/dev/null || true
    echo "" > "$G/UDC" 2>/dev/null || true
    sleep 1
    [ -w "$ROLE_NODE" ] && echo device > "$ROLE_NODE" 2>/dev/null || true
    echo "$UDC" > "$G/UDC" 2>/dev/null || true
  fi
}
( sleep 6; rebind_if_detached ) >/dev/null 2>&1 &
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


# 7c. Ensure NetworkManager writes real DHCP DNS directly into /etc/resolv.conf (no systemd-resolved)
cat > "$STAGE/etc/NetworkManager/conf.d/10-bitra-dns-default.conf" << "NMDNS"
[main]
dns=default
NMDNS

# 7d. Disable Wi-Fi Power Save for low-latency 24/7 headless server (avoids 300-1200ms QCA6390 ping spikes)
cat > "$STAGE/etc/NetworkManager/conf.d/zz-bitra-wifi-powersave-off.conf" << "NMPS"
[connection]
wifi.powersave = 2
NMPS

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


# 11. External SDX55M 5G Modem suite (GPIO + Sahara v2 + EFS Sync + QRTR TFTP + optional SIM slot init)
cat > "$STAGE/etc/udev/rules.d/99-bitra-sdx55-sahara.rules" << "SDXUDEV"
SUBSYSTEM=="wwan", KERNEL=="wwan*sahara*", ENV{ID_MM_PORT_IGNORE}="1"
SUBSYSTEM=="wwan", KERNEL=="wwan*efs*", ENV{ID_MM_PORT_IGNORE}="1"
SUBSYSTEM=="wwan", KERNEL=="wwan*qmi*", ENV{ID_MM_PORT_IGNORE}="1"
SUBSYSTEM=="net", KERNEL=="mhi_hwip*|mhi_swip*", ENV{ID_MM_PORT_IGNORE}="1"
SDXUDEV

cat > "$STAGE/etc/default/bitra-sdx55" << "SDXDEF"
# Optional SDX55M initial SIM slot selection before ModemManager starts.
# Leave empty to keep modem default (Slot 1 / SUB1), or set SIM_SLOT=2 for Slot 2 (SUB2).
SIM_SLOT=""
SDXDEF

cat > "$STAGE/usr/sbin/bitra-sdx55-gpio.py" << "SDXGPIO"
#!/usr/bin/env python3
"""Read/set SM8250 TLMM GPIOs via Linux GPIO cdev ABI v2 (zero external deps)."""
import fcntl, os, struct, sys, time

GPIO_V2_GET_LINE_IOCTL = 0xC250B407
GPIO_V2_LINE_GET_VALUES_IOCTL = 0xC010B40E
GPIO_V2_LINE_SET_VALUES_IOCTL = 0xC010B40F
FLAG_INPUT  = 1 << 2
FLAG_OUTPUT = 1 << 3

def find_tlmm_chip():
    for i in range(8):
        p = f"/sys/bus/gpio/devices/gpiochip{i}/of_node/compatible"
        try:
            if "qcom,sm8250-pinctrl" in open(p, "rb").read().decode("ascii", "ignore"):
                return f"/dev/gpiochip{i}"
        except OSError:
            pass
    return "/dev/gpiochip3"

def req_lines(chip, offsets, flags, consumer=b"bitra-mdm"):
    buf = bytearray(592)
    for i, off in enumerate(offsets):
        struct.pack_into("<I", buf, i * 4, off)
    buf[256:256+len(consumer)] = consumer
    struct.pack_into("<Q", buf, 288, flags)
    struct.pack_into("<I", buf, 560, len(offsets))
    cfd = os.open(chip, os.O_RDWR)
    try:
        fcntl.ioctl(cfd, GPIO_V2_GET_LINE_IOCTL, buf)
    finally:
        os.close(cfd)
    return struct.unpack_from("<i", buf, 588)[0]

def get_vals(lfd, n):
    buf = bytearray(16)
    struct.pack_into("<QQ", buf, 0, 0, (1 << n) - 1)
    fcntl.ioctl(lfd, GPIO_V2_LINE_GET_VALUES_IOCTL, buf)
    bits = struct.unpack_from("<Q", buf, 0)[0]
    return [(bits >> i) & 1 for i in range(n)]

def set_vals(lfd, vals):
    bits = 0
    for i, v in enumerate(vals):
        if v: bits |= (1 << i)
    buf = bytearray(struct.pack("<QQ", bits, (1 << len(vals)) - 1))
    fcntl.ioctl(lfd, GPIO_V2_LINE_SET_VALUES_IOCTL, buf)

chip = find_tlmm_chip()
cmd = sys.argv[1] if len(sys.argv) > 1 else "read"
if cmd == "read":
    lfd = req_lines(chip, [1, 3], FLAG_INPUT)
    v = get_vals(lfd, 2)
    os.close(lfd)
    print(f"mdm2ap_errfatal(1)={v[0]} mdm2ap_status(3)={v[1]} ({chip})")
elif cmd == "hold":
    lfd = req_lines(chip, [56, 57], FLAG_OUTPUT)
    set_vals(lfd, [1, 0])
    print(f"ap2mdm_status(56)=1 ap2mdm_errfatal(57)=0 HELD ({chip})", flush=True)
    while True:
        time.sleep(60)
SDXGPIO
chmod 755 "$STAGE/usr/sbin/bitra-sdx55-gpio.py"

cat > "$STAGE/usr/sbin/bitra-sdx55-sahara.py" << "SDXSAH"
#!/usr/bin/env python3
"""Minimal Qualcomm Sahara v2 image loader for flashless SDX55M over /dev/wwan0sahara0."""
import errno, os, select, struct, sys, time

DEV_PATH = sys.argv[1] if len(sys.argv) > 1 else "/dev/wwan0sahara0"
FW_DIR = "/lib/firmware/updates/qcom/sdx55m"
EFS_RW_DIR = "/var/lib/bitra/sdx55m-efs-rw"
EFS_RO_DIR = "/var/lib/bitra/sdx55m-efs"
MAX_CHUNK = 16384

def efs_path(name):
    rw = os.path.join(EFS_RW_DIR, name)
    if os.path.isfile(rw) and os.path.getsize(rw) > 0:
        return rw
    return os.path.join(EFS_RO_DIR, name)

def build_image_table():
    return {
        6:  f"{FW_DIR}/apps.mbn",
        8:  f"{FW_DIR}/qdsp6sw.mbn",
        16: efs_path("mdm1m9kefs1.bin"),
        17: efs_path("mdm1m9kefs2.bin"),
        20: efs_path("mdm1m9kefs3.bin"),
        21: f"{FW_DIR}/sbl1.mbn",
        23: f"{FW_DIR}/aop.mbn",
        25: f"{FW_DIR}/tz.mbn",
        29: f"{FW_DIR}/acdb.mbn",
        33: f"{FW_DIR}/hyp.mbn",
        34: efs_path("mdmddr.bin"),
        36: f"{FW_DIR}/multi_image_qti.mbn",
        37: f"{FW_DIR}/multi_image.mbn",
        38: f"{FW_DIR}/xbl_cfg.elf",
        40: f"{FW_DIR}/apdp.mbn",
        41: f"{FW_DIR}/devcfg.mbn",
        42: f"{FW_DIR}/sec.elf",
    }

CMD_HELLO, CMD_HELLO_RESP, CMD_READ_DATA, CMD_END_OF_IMAGE, CMD_DONE, CMD_DONE_RESP = 1, 2, 3, 4, 5, 6
CMD_MEM_DEBUG, CMD_MEM_DEBUG64, CMD_READ_DATA64 = 0x09, 0x10, 0x12

def log(msg):
    print(f"[sahara {time.monotonic():.3f}] {msg}", flush=True)

def write_all(fd, data):
    view = memoryview(data)
    off = 0
    total = len(data)
    while off < total:
        chunk = view[off:off + MAX_CHUNK]
        while True:
            _, w, _ = select.select([], [fd], [], 10.0)
            if not w:
                raise TimeoutError("write timeout")
            try:
                n = os.write(fd, chunk)
                break
            except BlockingIOError:
                continue
        if n <= 0:
            raise OSError(errno.EIO, "short write")
        off += n

def main():
    if not os.path.isfile(f"{FW_DIR}/qdsp6sw.mbn"):
        log("SDX55M firmware not extracted yet (run bitra-extract-sdx55-fw); skipping.")
        return 0
    image_table = build_image_table()
    log(f"Opening {DEV_PATH}")
    fd = os.open(DEV_PATH, os.O_RDWR | os.O_NONBLOCK)
    open_files = {}
    last_img = None
    bytes_sent = {}
    try:
        while True:
            r, _, _ = select.select([fd], [], [], 10.0)
            if not r:
                log(f"TIMEOUT waiting for read (last_img={last_img})")
                return 10
            try:
                pkt = os.read(fd, 32768)
            except BlockingIOError:
                continue
            except OSError as e:
                log(f"read error (device likely switched EE): {e}")
                break
            if not pkt:
                log("EOF on sahara device")
                break
            if len(pkt) < 8:
                continue
            cmd, length = struct.unpack_from("<II", pkt, 0)
            if cmd == CMD_HELLO:
                ver, ver_min, max_pkt, mode = struct.unpack_from("<IIII", pkt, 8)
                log(f"HELLO ver={ver} min={ver_min} max_pkt={max_pkt} mode={mode}")
                resp = struct.pack("<IIIIII6I", CMD_HELLO_RESP, 0x30, 2, 1, 0, mode, 0,0,0,0,0,0)
                write_all(fd, resp)
            elif cmd in (CMD_READ_DATA, CMD_READ_DATA64):
                if cmd == CMD_READ_DATA:
                    img_id, offset, data_len = struct.unpack_from("<III", pkt, 8)
                else:
                    img_id, offset, data_len = struct.unpack_from("<QQQ", pkt, 8)
                path = image_table.get(img_id)
                if not path or not os.path.exists(path):
                    log(f"ERROR: missing img={img_id} path={path}")
                    return 2
                if img_id != last_img:
                    log(f"Serving img={img_id} ({os.path.basename(path)}, size={os.path.getsize(path)})")
                    last_img = img_id
                f = open_files.get(img_id)
                if f is None:
                    f = open(path, "rb")
                    open_files[img_id] = f
                f.seek(offset)
                data = f.read(data_len)
                if len(data) < data_len:
                    data += b"\x00" * (data_len - len(data))
                write_all(fd, data)
                bytes_sent[img_id] = bytes_sent.get(img_id, 0) + data_len
            elif cmd == CMD_END_OF_IMAGE:
                img_id, status = struct.unpack_from("<II", pkt, 8)
                log(f"END_OF_IMAGE img={img_id} status={status} sent={bytes_sent.get(img_id, 0)}")
                if img_id in open_files:
                    open_files.pop(img_id).close()
                if status != 0:
                    return 3
                write_all(fd, struct.pack("<II", CMD_DONE, 8))
            elif cmd == CMD_DONE_RESP:
                tx_status = struct.unpack_from("<I", pkt, 8)[0]
                log(f"DONE_RESP image_tx_status={tx_status}")
                if tx_status == 1:
                    log("SUCCESS: All images loaded! SDX55M booting AMSS!")
                    return 0
            elif cmd in (CMD_MEM_DEBUG, CMD_MEM_DEBUG64):
                log(f"WARNING: MEM_DEBUG cmd=0x{cmd:x} len={length}")
                return 4
            else:
                log(f"UNHANDLED cmd=0x{cmd:x} len={length}")
                return 5
    finally:
        for f in open_files.values():
            f.close()
        os.close(fd)
    return 0

if __name__ == "__main__":
    sys.exit(main())
SDXSAH
chmod 755 "$STAGE/usr/sbin/bitra-sdx55-sahara.py"

cat > "$STAGE/usr/sbin/bitra-sdx55-efs-sync.py" << "SDXEFS"
#!/usr/bin/env python3
"""Qualcomm Sahara EFS Sync daemon for SDX55M over /dev/wwan0efs0 (MHI ch 10/11).
Writes synced EFS copies safely to /var/lib/bitra/sdx55m-efs-rw/ without touching raw UFS."""
import errno, os, select, struct, sys, time

DEV_PATH = sys.argv[1] if len(sys.argv) > 1 else "/dev/wwan0efs0"
EFS_RW_DIR = "/var/lib/bitra/sdx55m-efs-rw"
CMD_HELLO, CMD_HELLO_RESP, CMD_END_OF_IMAGE, CMD_DONE, CMD_DONE_RESP = 1, 2, 4, 5, 6
CMD_RESET, CMD_RESET_RESP, CMD_MEM_DEBUG, CMD_MEM_READ, CMD_MEM_DEBUG64, CMD_MEM_READ64 = 7, 8, 9, 10, 16, 17

FILENAME_MAP = {
    "m9kefs1": "mdm1m9kefs1.bin",
    "m9kefs2": "mdm1m9kefs2.bin",
    "m9kefs3": "mdm1m9kefs3.bin",
    "m9kefsc": "mdm1m9kefsc.bin",
    "mdm1m9kefs1": "mdm1m9kefs1.bin",
    "mdm1m9kefs2": "mdm1m9kefs2.bin",
    "mdm1m9kefs3": "mdm1m9kefs3.bin",
    "mdm1m9kefsc": "mdm1m9kefsc.bin",
}

def log(msg):
    print(f"[efs-sync {time.monotonic():.3f}] {msg}", flush=True)

def write_all(fd, data):
    view = memoryview(data)
    off = 0
    while off < len(data):
        _, w, _ = select.select([], [fd], [], 10.0)
        if not w: raise TimeoutError("write timeout")
        try: n = os.write(fd, view[off:off + 16384])
        except BlockingIOError: continue
        if n <= 0: raise OSError(errno.EIO, "short write")
        off += n

def read_exact(fd, n, timeout=15.0):
    buf = bytearray()
    dl = time.monotonic() + timeout
    while len(buf) < n:
        rem = dl - time.monotonic()
        if rem <= 0: raise TimeoutError(f"read_exact({n}) got {len(buf)}")
        r, _, _ = select.select([fd], [], [], rem)
        if not r: raise TimeoutError(f"read_exact({n}) timeout got {len(buf)}")
        try: c = os.read(fd, min(32768, n - len(buf)))
        except BlockingIOError: continue
        if not c: raise EOFError()
        buf.extend(c)
    return bytes(buf)

def mem_read(fd, addr, length, is64):
    if is64: write_all(fd, struct.pack("<IIQQ", CMD_MEM_READ64, 24, addr, length))
    else: write_all(fd, struct.pack("<IIII", CMD_MEM_READ, 16, addr, length))
    return read_exact(fd, length, 15.0)

def safe_target_path(raw_name):
    base = os.path.basename(raw_name.strip().replace("\\", "/"))
    mapped = FILENAME_MAP.get(base, base)
    if not mapped or mapped in (".", ".."): mapped = "unknown_efs.bin"
    return os.path.join(EFS_RW_DIR, mapped)

def serve_device(dev_path):
    log(f"Opening {dev_path}")
    fd = os.open(dev_path, os.O_RDWR | os.O_NONBLOCK)
    try:
        while True:
            r, _, _ = select.select([fd], [], [], 30.0)
            if not r:
                if not os.path.exists(dev_path):
                    log("Device disappeared")
                    return
                continue
            try: pkt = os.read(fd, 32768)
            except BlockingIOError: continue
            except OSError as e:
                log(f"Read error: {e}")
                return
            if not pkt or len(pkt) < 8:
                return
            cmd, length = struct.unpack_from("<II", pkt, 0)
            if cmd == CMD_HELLO:
                ver, vmin, mpkt, mode = struct.unpack_from("<IIII", pkt, 8)
                log(f"HELLO ver={ver} mode={mode}")
                write_all(fd, struct.pack("<IIIIII6I", CMD_HELLO_RESP, 0x30, 2, 1, 0, mode, 0,0,0,0,0,0))
            elif cmd in (CMD_MEM_DEBUG, CMD_MEM_DEBUG64):
                is64 = (cmd == CMD_MEM_DEBUG64)
                taddr, tlen = struct.unpack_from("<QQ" if is64 else "<II", pkt, 8)
                tbl = mem_read(fd, taddr, tlen, is64)
                rsz = 64 if is64 else 52
                entries = []
                for o in range(0, len(tbl) - rsz + 1, rsz):
                    sv, addr, sz, desc, fn = struct.unpack_from("<QQQ20s20s" if is64 else "<III20s20s", tbl, o)
                    fn = fn.split(b"\x00", 1)[0].decode("ascii", "replace")
                    if fn and sz > 0:
                        entries.append((fn, addr, sz))
                for fn, addr, sz in entries:
                    t0 = time.monotonic()
                    buf = bytearray()
                    pos = 0
                    while pos < sz:
                        cl = min(16384, sz - pos)
                        buf.extend(mem_read(fd, addr + pos, cl, is64))
                        pos += cl
                    outp = safe_target_path(fn)
                    tmpp = outp + ".tmp"
                    with open(tmpp, "wb") as f:
                        f.write(buf)
                        f.flush()
                        os.fsync(f.fileno())
                    os.replace(tmpp, outp)
                    log(f"SYNCED {fn} -> {outp} ({len(buf)}B in {(time.monotonic()-t0)*1000:.0f}ms)")
                write_all(fd, struct.pack("<II", CMD_RESET, 8))
            elif cmd == CMD_RESET_RESP:
                log("EFS sync cycle complete")
            elif cmd == CMD_END_OF_IMAGE:
                write_all(fd, struct.pack("<II", CMD_DONE, 8))
            elif cmd == CMD_DONE_RESP:
                pass
            else:
                log(f"UNHANDLED cmd=0x{cmd:x} len={length}")
    finally:
        os.close(fd)

def main():
    os.makedirs(EFS_RW_DIR, exist_ok=True)
    while True:
        if not os.path.exists(DEV_PATH):
            time.sleep(0.5)
            continue
        try: serve_device(DEV_PATH)
        except Exception as e: log(f"Exception: {e}")
        time.sleep(0.5)

if __name__ == "__main__":
    sys.exit(main())
SDXEFS
chmod 755 "$STAGE/usr/sbin/bitra-sdx55-efs-sync.py"

cat > "$STAGE/usr/sbin/bitra-sdx55-sim-init.py" << "SDXSIM"
#!/usr/bin/env python3
"""Optional pre-ModemManager SIM slot selector for SDX55M (/etc/default/bitra-sdx55)."""
import os, select, sys, time

slot = os.environ.get("SIM_SLOT", "").strip()
if slot not in ("1", "2"):
    sys.exit(0)

dev = "/dev/wwan0at0"
for _ in range(40):
    if os.path.exists(dev):
        break
    time.sleep(0.5)
if not os.path.exists(dev):
    sys.exit(0)

time.sleep(3.0)
fd = os.open(dev, os.O_RDWR | os.O_NONBLOCK)
try:
    def at(cmd, wait=2.0):
        os.write(fd, (cmd + "\r").encode())
        dl = time.monotonic() + wait
        out = b""
        while time.monotonic() < dl:
            r, _, _ = select.select([fd], [], [], max(0.05, dl - time.monotonic()))
            if r:
                try: out += os.read(fd, 4096)
                except BlockingIOError: pass
                if b"\r\nOK\r\n" in out or b"ERROR" in out: break
        return out.decode("ascii", "replace").strip()

    idx = int(slot) - 1
    print(f"[sim-init] Selecting SIM_SLOT={slot} (AT$QCSIMAPP={idx}): {at(f'AT$QCSIMAPP={idx}')}", flush=True)
    print(f"[sim-init] AT+CFUN=1: {at('AT+CFUN=1', 3.0)}", flush=True)
finally:
    os.close(fd)
SDXSIM
chmod 755 "$STAGE/usr/sbin/bitra-sdx55-sim-init.py"

cat > "$STAGE/usr/sbin/bitra-extract-sdx55-fw" << "SDXEXT"
#!/bin/bash
# Safe, read-only on-device extractor for RMX3370 SDX55M firmware, MCFG, and EFS snapshot.
set -euo pipefail
MODEM_PART=$(readlink -f /dev/disk/by-partlabel/modem)
MNT=$(mktemp -d /tmp/bitra-modem-mnt.XXXXXX)
trap 'umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT

mount -o ro "$MODEM_PART" "$MNT"
mkdir -p /lib/firmware/updates/qcom/sdx55m /lib/firmware/modem_pr /var/lib/bitra/sdx55m-efs /var/lib/bitra/sdx55m-efs-rw /var/lib/tqftpserv/{readwrite,shared,hlos}
cp -a "$MNT/image/sdx55m/." /lib/firmware/updates/qcom/sdx55m/
cp -a "$MNT/image/modem_pr/." /lib/firmware/modem_pr/

for part in mdm1m9kefs1 mdm1m9kefs2 mdm1m9kefs3 mdmddr; do
  DEV=$(readlink -f "/dev/disk/by-partlabel/$part")
  dd if="$DEV" of="/var/lib/bitra/sdx55m-efs/${part}.bin" bs=1M status=none
  chmod 600 "/var/lib/bitra/sdx55m-efs/${part}.bin"
  [ -f "/var/lib/bitra/sdx55m-efs-rw/${part}.bin" ] || cp -a "/var/lib/bitra/sdx55m-efs/${part}.bin" "/var/lib/bitra/sdx55m-efs-rw/${part}.bin"
done
echo "[bitra-sdx55] Extracted SDX55M firmware, modem_pr, and read-only EFS snapshot successfully."
SDXEXT
chmod 755 "$STAGE/usr/sbin/bitra-extract-sdx55-fw"

if [ -x "$WS/out/tqftpserv-sdx55" ]; then
  cp "$WS/out/tqftpserv-sdx55" "$STAGE/usr/sbin/tqftpserv-sdx55"
  chmod 755 "$STAGE/usr/sbin/tqftpserv-sdx55"
fi

cat > "$STAGE/etc/systemd/system/bitra-ap2mdm-gpio.service" << "SDXUNIT1"
[Unit]
Description=Assert AP2MDM status GPIO for SDX55M modem
DefaultDependencies=no
After=systemd-udevd.service
Before=bitra-sdx55-sahara.service multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/sbin/bitra-sdx55-gpio.py hold
Restart=always
TimeoutStopSec=5
RestartSec=2

[Install]
WantedBy=multi-user.target
SDXUNIT1

cat > "$STAGE/etc/systemd/system/tqftpserv-sdx55.service" << "SDXUNIT2"
[Unit]
Description=QRTR TFTP service for SDX55M (Service 4096 versions 1..10)
After=local-fs.target
Before=bitra-sdx55-sahara.service
ConditionPathExists=/usr/sbin/tqftpserv-sdx55

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /var/lib/tqftpserv/readwrite /var/lib/tqftpserv/shared /var/lib/tqftpserv/hlos
ExecStart=/usr/sbin/tqftpserv-sdx55
Restart=always
TimeoutStopSec=5
RestartSec=2

[Install]
WantedBy=multi-user.target
SDXUNIT2

cat > "$STAGE/etc/systemd/system/bitra-sdx55-sahara.service" << "SDXUNIT3"
[Unit]
Description=Qualcomm Sahara v2 firmware loader for SDX55M
After=systemd-udevd.service local-fs.target bitra-ap2mdm-gpio.service tqftpserv-sdx55.service
Wants=bitra-ap2mdm-gpio.service tqftpserv-sdx55.service
Before=ModemManager.service
ConditionPathExists=/lib/firmware/updates/qcom/sdx55m/qdsp6sw.mbn

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for i in $(seq 1 40); do [ -e /dev/wwan0sahara0 ] && break; sleep 0.5; done; [ -e /dev/wwan0sahara0 ] && exec /usr/bin/python3 /usr/sbin/bitra-sdx55-sahara.py /dev/wwan0sahara0 || exit 0'
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
SDXUNIT3

cat > "$STAGE/etc/systemd/system/bitra-sdx55-efs-sync.service" << "SDXUNIT4"
[Unit]
Description=Qualcomm Sahara EFS Sync daemon for SDX55M (/dev/wwan0efs0)
After=bitra-sdx55-sahara.service
ConditionPathExists=/lib/firmware/updates/qcom/sdx55m/qdsp6sw.mbn

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/sbin/bitra-sdx55-efs-sync.py /dev/wwan0efs0
Restart=always
TimeoutStopSec=5
RestartSec=1

[Install]
WantedBy=multi-user.target
SDXUNIT4

cat > "$STAGE/etc/systemd/system/bitra-sdx55-sim-init.service" << "SDXUNIT5"
[Unit]
Description=Optional SDX55M SIM slot selector before ModemManager
After=bitra-sdx55-sahara.service
Before=ModemManager.service
ConditionPathExists=/lib/firmware/updates/qcom/sdx55m/qdsp6sw.mbn

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/bitra-sdx55
ExecStart=/usr/bin/python3 /usr/sbin/bitra-sdx55-sim-init.py

[Install]
WantedBy=multi-user.target
SDXUNIT5


# 12. Native QMI-over-QRTR 5G/4G Cellular Data Tool (bitra-wwan + rmnet_data0@mhi_hwip0)
cat > "$STAGE/etc/default/bitra-wwan" << "WWANDEF"
# Set WWAN_AUTOSTART=1 to bring up 5G/4G cellular data automatically on boot
WWAN_AUTOSTART=0
# SIM subscription slot for cellular data: 1 = Primary (Slot 1), 2 = Secondary (Slot 2)
WWAN_SLOT=1
# Carrier APN (leave empty to use carrier default, or set e.g. cmnet / 3gnet / ctnet)
WWAN_APN=""
# Route metric for rmnet_data0 (Wi-Fi is 600; 700 = automatic failover, 100 = prefer 5G/4G)
WWAN_METRIC=700
WWANDEF

cat > "$STAGE/usr/sbin/bitra-wwan" << "WWANPY"
#!/usr/bin/env python3
"""Native QMI-over-QRTR 5G/4G cellular data manager for RMX3370 SDX55M (rmnet_data0@mhi_hwip0)."""
import argparse, ctypes, os, select, signal, socket, struct, subprocess, sys, time

AF_QIPCRTR = 42
SOCK_DGRAM = 2
SVC_WDS = 1
SVC_NAS = 3
SVC_WDA = 26
NODE_MPSS = 3
PCIE_EP_TYPE = 3
PCIE_EP_IFACE = 4
MUX_ID = 1
PHYS_DEV = "mhi_hwip0"
RMNET_DEV = "rmnet_data0"
CONF_PATH = "/etc/default/bitra-wwan"

libc = ctypes.CDLL("libc.so.6", use_errno=True)

def load_conf():
    cfg = {"WWAN_AUTOSTART": "0", "WWAN_SLOT": "1", "WWAN_APN": "", "WWAN_METRIC": "700"}
    if os.path.isfile(CONF_PATH):
        for line in open(CONF_PATH):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg

def run(cmd, check=True):
    return subprocess.run(cmd, check=check, text=True, capture_output=True)

def ensure_mhi0_qrtr():
    """Safely rebind ONLY mhi0_IPCR (never touching Wi-Fi mhi1_IPCR) if MPSS QMI services are missing."""
    try:
        out = subprocess.check_output(["qrtr-lookup"], text=True, stderr=subprocess.DEVNULL)
        if any(line.split()[:1] == ["1"] and len(line.split()) >= 5 and line.split()[3] == str(NODE_MPSS) for line in out.splitlines()):
            return
    except Exception:
        pass
    unbind = "/sys/bus/mhi/drivers/qcom_mhi_qrtr/unbind"
    bind = "/sys/bus/mhi/drivers/qcom_mhi_qrtr/bind"
    if os.path.exists(unbind) and os.path.exists("/sys/bus/mhi/devices/mhi0_IPCR"):
        try:
            with open(unbind, "w") as f: f.write("mhi0_IPCR")
            time.sleep(0.25)
            with open(bind, "w") as f: f.write("mhi0_IPCR")
            time.sleep(1.0)
        except OSError:
            pass

def ensure_uim_provisioned():
    """Ensure DMS is online and newly swapped SIM cards have Primary/Secondary GW sessions activated."""
    run(["qmicli", "-d", f"qrtr://{NODE_MPSS}", "--dms-set-operating-mode=online"], check=False)
    r = run(["qmicli", "-d", f"qrtr://{NODE_MPSS}", "--uim-get-card-status"], check=False)
    if r.returncode != 0:
        return
    txt = r.stdout
    for slot_num, sess_label, sess_type in [
        (1, "Primary GW:", "primary-gw-provisioning"),
        (2, "Secondary GW:", "secondary-gw-provisioning"),
    ]:
        if f"{sess_label}   session doesn't exist" not in txt and f"{sess_label} session doesn't exist" not in txt:
            continue
        # Extract first USIM Application ID under Slot [slot_num]
        marker = f"Slot [{slot_num}]:"
        idx = txt.find(marker)
        if idx == -1:
            continue
        next_idx = txt.find(f"Slot [{slot_num + 1}]:", idx)
        block = txt[idx:next_idx] if next_idx != -1 else txt[idx:]
        lines = block.splitlines()
        for i, line in enumerate(lines):
            if "Application ID:" in line and i + 1 < len(lines):
                aid = lines[i + 1].strip()
                if aid and ":" in aid:
                    print(f"[bitra-wwan] Activating {sess_type} on Slot {slot_num} (AID {aid[:14]}...)", flush=True)
                    run([
                        "qmicli", "-d", f"qrtr://{NODE_MPSS}",
                        f"--uim-change-provisioning-session=slot={slot_num},activate=yes,session-type={sess_type},aid={aid}"
                    ], check=False)
                    time.sleep(2.0)
                break

def lookup_qrtr_svc(target_svc, target_node=NODE_MPSS, timeout=15.0):
    ensure_mhi0_qrtr()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            out = subprocess.check_output(["qrtr-lookup"], text=True, stderr=subprocess.DEVNULL)
            for line in out.splitlines():
                parts = line.split()
                if len(parts) >= 5 and parts[0].isdigit():
                    svc, ver, inst, node, port = map(int, parts[:5])
                    if svc == target_svc and node == target_node:
                        return (node, port)
        except Exception:
            pass
        time.sleep(0.5)
    raise RuntimeError(f"QRTR service {target_svc} on node {target_node} not found after {timeout}s")

def qrtr_open():
    fd = libc.socket(AF_QIPCRTR, SOCK_DGRAM, 0)
    if fd < 0:
        raise OSError(ctypes.get_errno(), "socket(AF_QIPCRTR)")
    return fd

def qrtr_sendto(fd, data, dst):
    sa = struct.pack("<HHII", AF_QIPCRTR, 0, dst[0], dst[1])
    n = libc.sendto(fd, ctypes.c_char_p(data), len(data), 0, ctypes.c_char_p(sa), len(sa))
    if n < 0:
        raise OSError(ctypes.get_errno(), "sendto(AF_QIPCRTR)")
    return n

def qrtr_recv(fd, timeout=10.0):
    r, _, _ = select.select([fd], [], [], timeout)
    if not r:
        raise TimeoutError("QRTR QMI response timeout")
    buf = ctypes.create_string_buffer(4096)
    n = libc.recvfrom(fd, buf, 4096, 0, None, None)
    if n < 0:
        raise OSError(ctypes.get_errno(), "recvfrom(AF_QIPCRTR)")
    return buf.raw[:n]

def tlv(t, val):
    return struct.pack("<BH", t, len(val)) + val

def parse_tlvs(data):
    res, i = {}, 0
    while i + 3 <= len(data):
        t, l = struct.unpack_from("<BH", data, i)
        res[t] = data[i+3:i+3+l]
        i += 3 + l
    return res

class QmiClient:
    def __init__(self, dst):
        self.dst = dst
        self.fd = qrtr_open()
        self.txn = 0

    def txrx(self, msg_id, tlvs=b"", timeout=15.0):
        self.txn = (self.txn % 0xFFFE) + 1
        pkt = struct.pack("<BHHH", 0x00, self.txn, msg_id, len(tlvs)) + tlvs
        qrtr_sendto(self.fd, pkt, self.dst)
        deadline = time.monotonic() + timeout
        while True:
            rem = deadline - time.monotonic()
            if rem <= 0:
                raise TimeoutError(f"QMI msg 0x{msg_id:04x} timeout")
            resp = qrtr_recv(self.fd, rem)
            if len(resp) < 7:
                continue
            flags, rtxn, rmsg, rlen = struct.unpack_from("<BHHH", resp, 0)
            if flags == 0x02 and rtxn == self.txn and rmsg == msg_id:
                parsed = parse_tlvs(resp[7:7+rlen])
                rc, err = struct.unpack_from("<HH", parsed[0x02], 0)
                return rc, err, parsed

    def close(self):
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1

def qmi_ipv4(raw):
    val = struct.unpack_from("<I", raw, 0)[0]
    return socket.inet_ntoa(struct.pack("!I", val))

def mask_to_prefix(mask_str):
    packed = struct.unpack("!I", socket.inet_aton(mask_str))[0]
    return bin(packed).count("1")

def setup_rmnet():
    run(["modprobe", "rmnet"], check=False)
    run(["ip", "link", "set", PHYS_DEV, "up"])
    chk = run(["ip", "link", "show", RMNET_DEV], check=False)
    if chk.returncode != 0:
        run(["ip", "link", "add", RMNET_DEV, "link", PHYS_DEV, "type", "rmnet", "mux_id", str(MUX_ID)])
    run(["ip", "link", "set", RMNET_DEV, "up"])

def ensure_nas_registered():
    """If modem is stuck in power-save/limited (e.g. after ModemManager AT init), cycle DMS RF once."""
    def is_ready():
        r = run(["qmicli", "-d", f"qrtr://{NODE_MPSS}", "--nas-get-serving-system"], check=False)
        out = r.stdout
        return ("Registration state: 'registered'" in out and "PS: 'attached'" in out and "Status: 'limited'" not in out)
    if is_ready():
        return
    # Give modem a few seconds on cold boot before cycling RF
    for _ in range(4):
        time.sleep(2.0)
        if is_ready():
            return
    print("[bitra-wwan] NAS not cleanly registered (limited/power-save); cycling DMS RF low-power -> online...", flush=True)
    run(["qmicli", "-d", f"qrtr://{NODE_MPSS}", "--dms-set-operating-mode=low-power"], check=False)
    time.sleep(2.0)
    run(["qmicli", "-d", f"qrtr://{NODE_MPSS}", "--dms-set-operating-mode=online"], check=False)
    for _ in range(10):
        time.sleep(1.5)
        if is_ready():
            print("[bitra-wwan] NAS registered and PS attached!", flush=True)
            return

def configure_wda():
    wda = QmiClient(lookup_qrtr_svc(SVC_WDA))
    try:
        # WDA Set Data Format (0x0020): raw-ip(2), ul/dl=qmap(5), dl_max_dgram=16, dl_max_size=16384, pcie ep=4
        tlvs = (
            tlv(0x11, struct.pack("<I", 2)) +
            tlv(0x12, struct.pack("<I", 5)) +
            tlv(0x13, struct.pack("<I", 5)) +
            tlv(0x15, struct.pack("<I", 16)) +
            tlv(0x16, struct.pack("<I", 16384)) +
            tlv(0x17, struct.pack("<II", PCIE_EP_TYPE, PCIE_EP_IFACE))
        )
        rc, err, _ = wda.txrx(0x0020, tlvs)
        if rc != 0:
            raise RuntimeError(f"WDA Set Data Format failed: rc={rc} err={err}")
    finally:
        wda.close()

def cmd_daemon(slot, apn, metric):
    print(f"[bitra-wwan] Starting 5G/4G QMI data session (slot={slot}, apn={apn or '<default>'}, metric={metric})", flush=True)
    ensure_mhi0_qrtr()
    ensure_uim_provisioned()
    ensure_nas_registered()
    configure_wda()
    setup_rmnet()
    wds = QmiClient(lookup_qrtr_svc(SVC_WDS))
    handle = None
    stop_flag = False

    def on_sig(signum, frame):
        nonlocal stop_flag
        stop_flag = True

    signal.signal(signal.SIGTERM, on_sig)
    signal.signal(signal.SIGINT, on_sig)

    try:
        # 1. Bind Mux Data Port (0x00A2)
        mux_tlvs = (
            tlv(0x10, struct.pack("<II", PCIE_EP_TYPE, PCIE_EP_IFACE)) +
            tlv(0x11, struct.pack("<B", MUX_ID)) +
            tlv(0x13, struct.pack("<I", 1))
        )
        rc, err, _ = wds.txrx(0x00A2, mux_tlvs)
        if rc != 0:
            raise RuntimeError(f"WDS Bind Mux Data Port failed: rc={rc} err={err}")

        # 2. Bind Subscription (0x00AF): 0 = Primary (Slot 1), 1 = Secondary (Slot 2)
        sub_id = 0 if int(slot) == 1 else 1
        rc, err, _ = wds.txrx(0x00AF, tlv(0x01, struct.pack("<I", sub_id)))
        print(f"[bitra-wwan] WDS Bind Subscription (slot={slot}, sub={sub_id}): rc={rc} err={err}", flush=True)

        # 3. Set IP Family (0x004D): IPv4 (4)
        rc, err, _ = wds.txrx(0x004D, tlv(0x01, struct.pack("<B", 4)))
        if rc != 0:
            raise RuntimeError(f"WDS Set IP Family failed: rc={rc} err={err}")

        # 4. Start Network Interface (0x0020) — retry cleanly while modem finishes 5G/4G attach on cold boot
        start_tlvs = b""
        if apn:
            start_tlvs += tlv(0x14, apn.encode("ascii"))
        for attempt in range(1, 21):
            if stop_flag:
                return
            rc, err, parsed = wds.txrx(0x0020, start_tlvs, timeout=30.0)
            if rc == 0:
                break
            reason = parsed.get(0x10, b"").hex()
            vreason = parsed.get(0x11, b"").hex()
            if err == 14 and attempt < 20:
                if attempt == 10:
                    print("[bitra-wwan] Modem still unattached; cycling RF low-power -> online...", flush=True)
                    run(["qmicli", "-d", f"qrtr://{NODE_MPSS}", "--dms-set-operating-mode=low-power"], check=False)
                    time.sleep(2.0)
                    run(["qmicli", "-d", f"qrtr://{NODE_MPSS}", "--dms-set-operating-mode=online"], check=False)
                elif attempt == 1 or attempt % 5 == 0:
                    print(f"[bitra-wwan] Waiting for 5G/4G cellular attach (attempt {attempt}/20, call_end={reason})...", flush=True)
                time.sleep(2.0)
                continue
            raise RuntimeError(f"WDS Start Network failed: rc={rc} err={err} call_end={reason} verbose={vreason}")
        handle = struct.unpack_from("<I", parsed[0x01], 0)[0]
        print(f"[bitra-wwan] Connected! packet_data_handle=0x{handle:08x}", flush=True)

        # 5. Get Current Settings (0x002D)
        req_mask = 0x0000EFF3
        rc, err, cfg = wds.txrx(0x002D, tlv(0x10, struct.pack("<I", req_mask)))
        if rc != 0:
            raise RuntimeError(f"WDS Get Current Settings failed: rc={rc} err={err}")

        ip = qmi_ipv4(cfg[0x1E])
        gw = qmi_ipv4(cfg[0x20])
        mask = qmi_ipv4(cfg[0x21])
        prefix = mask_to_prefix(mask)
        dns = []
        if 0x15 in cfg: dns.append(qmi_ipv4(cfg[0x15]))
        if 0x16 in cfg: dns.append(qmi_ipv4(cfg[0x16]))
        mtu = struct.unpack_from("<I", cfg[0x29], 0)[0] if 0x29 in cfg else 1500
        if mtu < 1280 or mtu > 1500:
            mtu = 1500

        print(f"[bitra-wwan] IP={ip}/{prefix} GW={gw} MTU={mtu} DNS={dns}", flush=True)
        run(["ip", "addr", "flush", "dev", RMNET_DEV], check=False)
        run(["ip", "link", "set", RMNET_DEV, "mtu", str(mtu)])
        run(["ip", "addr", "add", f"{ip}/{prefix}", "dev", RMNET_DEV])
        run(["ip", "route", "replace", "default", "via", gw, "dev", RMNET_DEV, "metric", str(metric)])

        with open("/run/bitra-wwan.env", "w") as f:
            f.write(f"WWAN_IP={ip}/{prefix}\nWWAN_GW={gw}\nWWAN_DNS={' '.join(dns)}\nWWAN_HANDLE=0x{handle:08x}\n")

        # If /etc/resolv.conf has no nameserver (e.g. Wi-Fi offline), populate carrier DNS
        try:
            cur_resolv = open("/etc/resolv.conf").read() if os.path.exists("/etc/resolv.conf") else ""
        except OSError:
            cur_resolv = ""
        if dns and "nameserver " not in cur_resolv:
            with open("/etc/resolv.conf", "w") as f:
                f.write("# Generated by bitra-wwan\n")
                for d in dns:
                    f.write(f"nameserver {d}\n")

        # Keep WDS client socket alive & monitor both WDS + NAS serving state every 15s
        nas = QmiClient(lookup_qrtr_svc(SVC_NAS))
        nas_bad = 0
        last_chk = time.monotonic()
        while not stop_flag:
            r, _, _ = select.select([wds.fd], [], [], 1.0)
            if r:
                try:
                    ind = os.read(wds.fd, 4096)
                    if len(ind) >= 7:
                        ictrl, _, imid, ilen = struct.unpack_from("<BHHH", ind, 0)
                        if ictrl == 0x04 and imid == 0x0022:
                            itlv = parse_tlvs(ind[7:7+ilen])
                            if 0x01 in itlv and len(itlv[0x01]) >= 1 and itlv[0x01][0] != 2:
                                print(f"[bitra-wwan] Carrier indicated disconnect (status={itlv[0x01][0]}), reconnecting...", flush=True)
                                raise RuntimeError("Carrier disconnected")
                except RuntimeError:
                    raise
                except Exception:
                    pass
            now = time.monotonic()
            if now - last_chk >= 15.0:
                last_chk = now
                try:
                    rc_s, _, pst = wds.txrx(0x0022, b"", timeout=5.0)
                    if rc_s == 0 and 0x01 in pst and len(pst[0x01]) >= 1 and pst[0x01][0] != 2:
                        print(f"[bitra-wwan] Packet session lost (status={pst[0x01][0]}), reconnecting...", flush=True)
                        raise RuntimeError("Packet session lost")
                    rc_n, _, nst = nas.txrx(0x0024, b"", timeout=5.0)
                    if rc_n == 0 and 0x01 in nst and len(nst[0x01]) >= 3:
                        reg, ps = nst[0x01][0], nst[0x01][2]
                        if reg != 1 or ps != 1:
                            nas_bad += 1
                            if nas_bad >= 2:
                                print(f"[bitra-wwan] NAS detached (reg={reg}, ps={ps}), reconnecting...", flush=True)
                                raise RuntimeError("NAS detached")
                        else:
                            nas_bad = 0
                except RuntimeError:
                    raise
                except Exception as e:
                    print(f"[bitra-wwan] Status check warning: {e}", flush=True)
    finally:
        if handle is not None:
            try:
                print(f"[bitra-wwan] Stopping network handle=0x{handle:08x}...", flush=True)
                wds.txrx(0x0021, tlv(0x01, struct.pack("<I", handle)), timeout=5.0)
            except Exception as e:
                print(f"[bitra-wwan] Stop network warning: {e}", flush=True)
        run(["ip", "route", "del", "default", "dev", RMNET_DEV], check=False)
        run(["ip", "addr", "flush", "dev", RMNET_DEV], check=False)
        if os.path.exists("/run/bitra-wwan.env"):
            os.remove("/run/bitra-wwan.env")
        try:
            nas.close()
        except Exception:
            pass
        wds.close()

def cmd_status():
    ensure_mhi0_qrtr()
    print("=== QRTR QMI Services (WDS/WDA/NAS/UIM) ===")
    try:
        out = subprocess.check_output(["qrtr-lookup"], text=True)
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 5 and p[0] in ("1", "2", "3", "5", "11", "26"):
                print(" ", line)
    except Exception as e:
        print("  qrtr-lookup error:", e)
    print("=== SIM Slots & Signal (qrtr://3) ===")
    for flag in ("--uim-get-slot-status", "--nas-get-signal-info", "--nas-get-serving-system"):
        r = run(["qmicli", "-d", "qrtr://3", flag], check=False)
        if r.returncode == 0:
            for line in r.stdout.splitlines():
                if any(k in line for k in ("slot", "Card status", "Slot status", "5G:", "LTE:", "GSM:", "RSRP", "SNR", "RSSI", "Registration state", "PS:", "CS:", "MCC:", "MNC:", "Radio interfaces")):
                    print(" ", line)
    print("=== Cellular Interface (rmnet_data0) ===")
    r = run(["ip", "-4", "addr", "show", RMNET_DEV], check=False)
    print(r.stdout.strip() if r.returncode == 0 else "  rmnet_data0 not created yet")
    if os.path.isfile("/run/bitra-wwan.env"):
        print("=== Active Session (/run/bitra-wwan.env) ===")
        print(open("/run/bitra-wwan.env").read().strip())

def main():
    cfg = load_conf()
    ap = argparse.ArgumentParser(description="RMX3370 SDX55M 5G/4G QMI cellular data manager")
    ap.add_argument("action", choices=["up", "down", "status", "daemon"])
    ap.add_argument("--slot", type=int, default=int(cfg["WWAN_SLOT"] or 1))
    ap.add_argument("--apn", default=cfg["WWAN_APN"])
    ap.add_argument("--metric", type=int, default=int(cfg["WWAN_METRIC"] or 700))
    ap.add_argument("--foreground", "-f", action="store_true", help="Run in foreground instead of systemd service")
    args = ap.parse_args()

    if args.action == "status":
        cmd_status()
    elif args.action == "up":
        if args.foreground:
            cmd_daemon(args.slot, args.apn, args.metric)
        else:
            os.execvp("systemctl", ["systemctl", "start", "bitra-wwan.service"])
    elif args.action == "down":
        os.execvp("systemctl", ["systemctl", "stop", "bitra-wwan.service"])
    elif args.action == "daemon":
        cmd_daemon(args.slot, args.apn, args.metric)

if __name__ == "__main__":
    sys.exit(main())
WWANPY
chmod 755 "$STAGE/usr/sbin/bitra-wwan"

cat > "$STAGE/etc/systemd/system/bitra-wwan.service" << "WWANUNIT"
[Unit]
Description=RMX3370 SDX55M 5G/4G Cellular Data (QMI over QRTR + rmnet_data0)
After=bitra-sdx55-sahara.service qrtr-ns.service ModemManager.service
Wants=qrtr-ns.service

[Service]
Type=simple
EnvironmentFile=-/etc/default/bitra-wwan
ExecStart=/usr/sbin/bitra-wwan daemon
TimeoutStopSec=10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
WWANUNIT

# 13. Optional Phosh Mobile Touch Desktop & Headless OLED True-DPMS-Off (anti-burn-in)
mkdir -p "$STAGE/etc/phosh"
cat > "$STAGE/etc/phosh/phoc.ini" << "PHOCINI"
[output:DSI-1]
scale = 2
PHOCINI

mkdir -p "$STAGE/etc/xdg/xdg-desktop-portal"
cat > "$STAGE/etc/xdg/xdg-desktop-portal/phosh-portals.conf" << "PORTALCONF"
[preferred]
default=gtk
org.freedesktop.impl.portal.Access=phosh;gtk;
org.freedesktop.impl.portal.Background=none;
org.freedesktop.impl.portal.Clipboard=none;
org.freedesktop.impl.portal.InputCapture=none;
org.freedesktop.impl.portal.RemoteDesktop=none;
org.freedesktop.impl.portal.ScreenCast=none;
org.freedesktop.impl.portal.Screenshot=none;
org.freedesktop.impl.portal.Secret=none;
org.freedesktop.impl.portal.Wallpaper=none;
PORTALCONF

cat > "$STAGE/usr/sbin/bitra-desktop" << "DESKSH"
#!/bin/bash
set -euo pipefail

BL_DIR="/sys/class/backlight/ae94000.dsi.0"
FB_BLANK="/sys/class/graphics/fb0/blank"

oled_off() {
  [ -w "$BL_DIR/brightness" ] && echo 0 > "$BL_DIR/brightness" 2>/dev/null || true
  if [ -w "$FB_BLANK" ]; then
    echo 4 > "$FB_BLANK" 2>/dev/null || true
  elif [ -c /dev/dri/card0 ] && command -v python3 >/dev/null 2>&1; then
    python3 - << "DRMPY" 2>/dev/null || true
import array, ctypes, fcntl, os, struct
fd = os.open("/dev/dri/card0", os.O_RDWR)
try:
    # DRM_IOCTL_MODE_GETRESOURCES = 0xc04064a0
    res = bytearray(64)
    fcntl.ioctl(fd, 0xc04064a0, res)
    _, n_crtcs, _, _ = struct.unpack_from("=IIII", res, 32)
    if n_crtcs > 0:
        crtcs = (ctypes.c_uint32 * n_crtcs)()
        struct.pack_into("=QQQQIIII", res, 0, 0, ctypes.addressof(crtcs), 0, 0, 0, n_crtcs, 0, 0)
        fcntl.ioctl(fd, 0xc04064a0, res)
        # DRM_IOCTL_MODE_SETCRTC = 0xc06864a2 (fb_id=0, count_connectors=0 disables CRTC)
        for cid in crtcs:
            req = bytearray(104)
            struct.pack_into("=QII", req, 0, 0, 0, cid)
            try:
                fcntl.ioctl(fd, 0xc06864a2, req)
            except OSError:
                pass
finally:
    os.close(fd)
DRMPY
  fi
}

oled_on() {
  local level="${1:-800}"
  [ -w "$FB_BLANK" ] && echo 0 > "$FB_BLANK" 2>/dev/null || true
  [ -w "$BL_DIR/brightness" ] && echo "$level" > "$BL_DIR/brightness" 2>/dev/null || true
}

case "${1:-status}" in
  start)
    if ! systemctl list-unit-files phosh.service >/dev/null 2>&1; then
      echo "Phosh is not installed. Install with: sudo apt-get install phosh phoc phosh-osk-stub"
      exit 1
    fi
    systemctl start phosh.service
    sleep 1
    oled_on 600
    echo "[bitra-desktop] Phosh started on DSI-1."
    ;;
  stop)
    systemctl stop phosh.service 2>/dev/null || true
    sleep 1
    oled_off
    echo "[bitra-desktop] Phosh stopped; OLED powered off (DPMS blank)."
    ;;
  blank)
    oled_off
    echo "[bitra-desktop] OLED powered off (DPMS blank)."
    ;;
  unblank)
    oled_on "${2:-800}"
    echo "[bitra-desktop] OLED powered on (brightness=${2:-800})."
    ;;
  enable)
    systemctl enable phosh.service
    systemctl set-default graphical.target
    echo "[bitra-desktop] Enabled Phosh on boot (graphical.target)."
    ;;
  disable)
    systemctl disable phosh.service 2>/dev/null || true
    systemctl set-default multi-user.target
    echo "[bitra-desktop] Disabled Phosh on boot (headless multi-user.target default)."
    ;;
  status)
    echo "Default target : $(systemctl get-default)"
    echo "Phosh service  : $(systemctl is-active phosh.service 2>/dev/null || true) ($(systemctl is-enabled phosh.service 2>/dev/null || true))"
    [ -r "$BL_DIR/brightness" ] && echo "OLED backlight : $(cat "$BL_DIR/brightness") / $(cat "$BL_DIR/max_brightness")" || echo "OLED backlight : unavailable"
    [ -r "$FB_BLANK" ] && echo "FB0 blank      : $(cat "$FB_BLANK")" || true
    [ -e /dev/dri/card0 ] && echo "DRM / GPU      : /dev/dri/card0 + $(ls /dev/dri/renderD* 2>/dev/null | tr '\n' ' ')" || echo "DRM / GPU      : unavailable"
    grep -l "Synaptics S3908" /sys/class/input/event*/device/name 2>/dev/null | sed 's|/device/name||' | xargs -r -I{} echo "Touchscreen    : {} (Synaptics S3908)"
    ;;
  *)
    echo "Usage: bitra-desktop {start|stop|blank|unblank [brightness]|enable|disable|status}"
    exit 2
    ;;
esac
DESKSH
chmod 755 "$STAGE/usr/sbin/bitra-desktop"

cat > "$STAGE/etc/systemd/system/bitra-oled-blank.service" << "OLEDBLANK"
[Unit]
Description=RMX3370 Headless OLED True-DPMS Power-Off (Anti-Burn-In)
After=systemd-udev-settle.service local-fs.target getty@tty1.service
ConditionPathExists=!/run/bitra-keep-oled-on

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for i in $(seq 1 20); do [ -e /sys/class/graphics/fb0/blank ] && break; sleep 0.5; done; if ! systemctl is-active --quiet phosh.service; then sleep 2; /usr/sbin/bitra-desktop blank; fi'

[Install]
WantedBy=multi-user.target
OLEDBLANK

# 13a-wp. WirePlumber ALSA S16_LE rule for Qualcomm q6asm-dai
# PipeWire defaults to S24_LE when q6asm-dai advertises S16_LE|S24_LE, which
# triggers an 8-bit (-48 dB) right-shift when routing into the 16-bit
# TERTIARY_MI2S_RX backend on SM8250. Forcing S16LE restores full loudness.
cat > "$STAGE/etc/wireplumber/main.lua.d/51-bitra-alsa-s16.lua" << 'WPEOF'
table.insert(alsa_monitor.rules, {
  matches = {
    {
      { "node.name", "matches", "alsa_output.platform-sound.*" },
    },
    {
      { "node.name", "matches", "alsa_input.platform-sound.*" },
    },
  },
  apply_properties = {
    ["audio.format"] = "S16LE",
  },
})
WPEOF

# 13a-udev. udev rule so iio-sensor-proxy enables all Qualcomm SSC sensors on /dev/fastrpc-sdsp
mkdir -p "$STAGE/etc/udev/rules.d"
cat > "$STAGE/etc/udev/rules.d/81-bitra-ssc-sensors.rules" << 'UDEVEOF'
SUBSYSTEM=="misc", KERNEL=="fastrpc-sdsp*", ENV{IIO_SENSOR_PROXY_TYPE}+="ssc-accel ssc-light ssc-proximity ssc-compass"
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="aw8697-haptics", TAG+="uaccess", ENV{FEEDBACKD_TYPE}="vibra"
UDEVEOF

# 13a-slpi. HexagonRPC reverse-tunnel daemon for SLPI sensors (/dev/fastrpc-sdsp)
cat > "$STAGE/etc/systemd/system/hexagonrpcd-sdsp.service" << 'HEXEOF'
[Unit]
Description=Qualcomm SLPI/SDSP HexagonRPC Sensor Daemon
ConditionPathExists=/usr/bin/hexagonrpcd
After=pd-mapper.service local-fs.target
Wants=pd-mapper.service

[Service]
Type=simple
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do [ -c /dev/fastrpc-sdsp ] && exit 0; sleep 0.5; done; exit 0'
ExecStart=/usr/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /usr/share/qcom/sm8250/realme/bitra
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
HEXEOF

mkdir -p "$STAGE/etc/systemd/system/iio-sensor-proxy.service.d"
cat > "$STAGE/etc/systemd/system/iio-sensor-proxy.service.d/after-hexagonrpcd.conf" << 'IIOEOF'
[Unit]
After=hexagonrpcd-sdsp.service
Wants=hexagonrpcd-sdsp.service

[Service]
ExecStartPre=/bin/sleep 8
IIOEOF

# 13a-2. Disable legacy fbdev on headless boot (keeps OLED completely off from boot; Wayland/Phosh uses DRM/KMS directly)
mkdir -p "$STAGE/etc/modprobe.d"
cat > "$STAGE/etc/modprobe.d/bitra-msm.conf" << "MSMEOF"
options msm fbdev=0
options drm_kms_helper fbdev_emulation=0
MSMEOF

# 13b. Persistent USB CDC-ECM auto-recovery watchdog (handles macOS sleep/wake, replug & tcpm TOGGLING)
cat > "$STAGE/usr/sbin/bitra-usb-watch" << "USBWSH"
#!/bin/bash
set -u

UDC="/sys/class/udc/a600000.usb"
ROLE="/sys/class/usb_role/a600000.usb-role-switch/role"
ONLINE="/sys/class/power_supply/mp2650-charger/online"
GADGET_UDC="/sys/kernel/config/usb_gadget/g1/UDC"

BAD_COUNT=0
while true; do
  sleep 4
  [ -r "$ONLINE" ] && [ "$(cat "$ONLINE" 2>/dev/null || echo 0)" = "1" ] || { BAD_COUNT=0; continue; }
  [ -r "$ROLE" ] && [ "$(cat "$ROLE" 2>/dev/null || echo device)" = "host" ] && { BAD_COUNT=0; continue; }
  STATE="$(cat "$UDC/state" 2>/dev/null || echo unknown)"
  if [ "$STATE" = "configured" ] || [ "$STATE" = "suspended" ]; then
    BAD_COUNT=0
    continue
  fi
  BAD_COUNT=$((BAD_COUNT + 1))
  if [ "$BAD_COUNT" -ge 2 ]; then
    BAD_COUNT=0
    logger -t bitra-usb-watch "USB gadget state=$STATE while VBUS online; cycling soft_connect"
    [ -w "$ROLE" ] && echo device > "$ROLE" 2>/dev/null || true
    if [ -r "$GADGET_UDC" ] && [ -z "$(cat "$GADGET_UDC" 2>/dev/null || true)" ]; then
      echo a600000.usb > "$GADGET_UDC" 2>/dev/null || true
    fi
    if [ -w "$UDC/soft_connect" ]; then
      echo disconnect > "$UDC/soft_connect" 2>/dev/null || true
      sleep 1
      echo connect > "$UDC/soft_connect" 2>/dev/null || true
    fi
    sleep 2
    ip link set usb0 up 2>/dev/null || true
    ip addr replace 192.168.2.15/24 dev usb0 2>/dev/null || true
    if command -v dnsmasq >/dev/null 2>&1; then
      pkill -f "dnsmasq.*bitra-usb" 2>/dev/null || true
      dnsmasq --interface=usb0 --bind-dynamic --port=0 --dhcp-authoritative \
        --dhcp-range=192.168.2.20,192.168.2.30,255.255.255.0,12h \
        --dhcp-option=3 --dhcp-option=6 \
        --dhcp-leasefile=/run/bitra-usb-dhcp.leases \
        --pid-file=/run/bitra-usb-dnsmasq.pid 2>/dev/null || true
    fi
    # Back off 10s after recovery attempt so we do not spam if plugged into a dumb charger
    sleep 10
  fi
done
USBWSH
chmod 755 "$STAGE/usr/sbin/bitra-usb-watch"

cat > "$STAGE/etc/systemd/system/bitra-usb-watch.service" << "USBWUNIT"
[Unit]
Description=RMX3370 USB CDC-ECM Auto-Recovery Watchdog (preserves OTG host mode)
After=bitra-usb-gadget.service

[Service]
Type=simple
ExecStart=/usr/sbin/bitra-usb-watch
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
USBWUNIT

# 14. QCA6390 Bluetooth deterministic public address (before bluetooth.service)
cat > "$STAGE/usr/sbin/bitra-bt-addr" << "BTSH"
#!/bin/bash
set -euo pipefail

BTMAC=$(python3 - << "PYMAC"
import hashlib
mid = open("/etc/machine-id").read().strip().encode()
h = hashlib.sha256(mid + b"-bitra-bt").digest()
b = bytearray(h[:6])
b[0] = (b[0] & 0xfe) | 0x02  # locally administered unicast
print(":".join(f"{x:02X}" for x in b))
PYMAC
)

# Wait for QCA6390 UART firmware download (htbtfw20.tlv + htnv20.bin) to complete,
# then set deterministic public address via `true | btmgmt` (avoids epoll EPERM on /dev/null).
for i in $(seq 1 40); do
  if [ -d /sys/class/bluetooth/hci0 ]; then
    if true | timeout 3 btmgmt --index 0 info 2>/dev/null | grep -qiE "addr [0-9a-f:]{17}" &&        ! true | timeout 3 btmgmt --index 0 info 2>/dev/null | grep -qi "00:00:00:00:5a:ad"; then
      echo "[bitra-bt-addr] hci0 already configured."
      exit 0
    fi
    if true | timeout 3 btmgmt --index 0 public-addr "$BTMAC" 2>/dev/null; then
      echo "[bitra-bt-addr] Configured hci0 public address: $BTMAC"
      exit 0
    fi
  fi
  sleep 0.5
done
echo "[bitra-bt-addr] Warning: timed out waiting for hci0 setup." >&2
exit 0
BTSH
chmod 755 "$STAGE/usr/sbin/bitra-bt-addr"

cat > "$STAGE/etc/systemd/system/bitra-bt-addr.service" << "BTUNIT"
[Unit]
Description=RMX3370 QCA6390 Bluetooth Public Address Setup
After=systemd-udev-settle.service
Before=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/bitra-bt-addr
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
BTUNIT

# 15. ALSA UCM2 profile for realme-GT-Neo2-bitra (Dual TFA9874 Speakers + WCD9380 Dual Analog Mics)
mkdir -p "$STAGE/usr/share/alsa/ucm2/Qualcomm/sm8250" "$STAGE/usr/share/alsa/ucm2/conf.d/sm8250"
cat > "$STAGE/usr/share/alsa/ucm2/Qualcomm/sm8250/realme-GT-Neo2-bitra.conf" << "UCMTOP"
Syntax 4

SectionUseCase."HiFi" {
	File "/Qualcomm/sm8250/realme-GT-Neo2-bitra-HiFi.conf"
	Comment "HiFi quality Music."
}
UCMTOP

cat > "$STAGE/usr/share/alsa/ucm2/Qualcomm/sm8250/realme-GT-Neo2-bitra-HiFi.conf" << "UCMHIFI"
SectionVerb {
	# Place FE->BE mixer routing in Verb EnableSequence so PipeWire/ACP
	# can open playback and capture PCMs cleanly during cold-boot probing.
	EnableSequence [
		cset "name='TERT_MI2S_RX Audio Mixer MultiMedia1' 1"
		cset "name='SpkrLeft Speaker Volume' 8"
		cset "name='SpkrRight Speaker Volume' 9"
		cset "name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3' 1"
		cset "name='TX_AIF1_CAP Mixer DEC0' 1"
		cset "name='TX_AIF1_CAP Mixer DEC1' 1"
		cset "name='TX DEC0 MUX' SWR_MIC"
		cset "name='TX DEC1 MUX' SWR_MIC"
		cset "name='TX SMIC MUX0' ADC0"
		cset "name='TX SMIC MUX1' ADC3"
		cset "name='ADC1_MIXER Switch' 1"
		cset "name='ADC4_MIXER Switch' 1"
		cset "name='ADC1 Switch' 1"
		cset "name='ADC4 Switch' 1"
		cset "name='ADC4 MUX' INP5"
		cset "name='ADC1 Volume' 12"
		cset "name='ADC4 Volume' 12"
		cset "name='TX_DEC0 Volume' 84"
		cset "name='TX_DEC1 Volume' 84"
	]

	DisableSequence [
		cset "name='TERT_MI2S_RX Audio Mixer MultiMedia1' 0"
		cset "name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3' 0"
	]

	Value {
		TQ "HiFi"
	}
}

SectionDevice."Speaker" {
	Comment "Stereo Speakers (Dual TFA9874)"

	EnableSequence [
		cset "name='TERT_MI2S_RX Audio Mixer MultiMedia1' 1"
	]

	Value {
		PlaybackPriority 200
		PlaybackPCM "hw:${CardId},0"
		PlaybackChannels 2
	}
}

SectionDevice."Mic" {
	Comment "Internal Microphones (WCD9380 AMIC1 + AMIC5)"

	EnableSequence [
		cset "name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3' 1"
		cset "name='ADC1 Switch' 1"
		cset "name='ADC4 Switch' 1"
	]

	DisableSequence [
		cset "name='ADC1 Switch' 0"
		cset "name='ADC4 Switch' 0"
	]

	Value {
		CapturePriority 200
		CapturePCM "hw:${CardId},2"
		CaptureChannels 2
	}
}
UCMHIFI
ln -sf ../../Qualcomm/sm8250/realme-GT-Neo2-bitra.conf "$STAGE/usr/share/alsa/ucm2/conf.d/sm8250/realme-GT-Neo2-bitra.conf"

cat > "$STAGE/DEBIAN/conffiles" << CONF
/etc/default/bitra-wwan
/etc/phosh/phoc.ini
/etc/xdg/xdg-desktop-portal/phosh-portals.conf
CONF

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
rm -f /etc/NetworkManager/conf.d/99-bitra-wifi-powersave-off.conf
if [ -d /etc/systemd/system/multi-user.target.wants ]; then
  ln -sf /etc/systemd/system/bitra-usb-gadget.service /etc/systemd/system/multi-user.target.wants/bitra-usb-gadget.service
  mkdir -p /etc/systemd/system/timers.target.wants
  ln -sf /etc/systemd/system/bitra-charge-limit.timer /etc/systemd/system/timers.target.wants/bitra-charge-limit.timer
  ln -sf /etc/systemd/system/bitra-ap2mdm-gpio.service /etc/systemd/system/multi-user.target.wants/bitra-ap2mdm-gpio.service
  ln -sf /etc/systemd/system/tqftpserv-sdx55.service /etc/systemd/system/multi-user.target.wants/tqftpserv-sdx55.service
  ln -sf /etc/systemd/system/bitra-sdx55-sahara.service /etc/systemd/system/multi-user.target.wants/bitra-sdx55-sahara.service
  ln -sf /etc/systemd/system/bitra-sdx55-efs-sync.service /etc/systemd/system/multi-user.target.wants/bitra-sdx55-efs-sync.service
  ln -sf /etc/systemd/system/bitra-sdx55-sim-init.service /etc/systemd/system/multi-user.target.wants/bitra-sdx55-sim-init.service
  ln -sf /etc/systemd/system/bitra-oled-blank.service /etc/systemd/system/multi-user.target.wants/bitra-oled-blank.service
  ln -sf /etc/systemd/system/bitra-bt-addr.service /etc/systemd/system/multi-user.target.wants/bitra-bt-addr.service
  ln -sf /etc/systemd/system/bitra-usb-watch.service /etc/systemd/system/multi-user.target.wants/bitra-usb-watch.service
  if [ -f /usr/lib/systemd/system/pd-mapper.service ]; then ln -sf /usr/lib/systemd/system/pd-mapper.service /etc/systemd/system/multi-user.target.wants/pd-mapper.service; fi
  # Prevent systemd-backlight from fighting bitra-oled-blank.service on headless boots
  ln -sf /dev/null /etc/systemd/system/systemd-backlight@backlight:ae94000.dsi.0.service
fi
exit 0
POST
chmod 755 "$STAGE/DEBIAN/postinst"

DEB="$PKG_DIR/bitra-device-support_${VER}_arm64.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB"
ls -lh "$DEB"
