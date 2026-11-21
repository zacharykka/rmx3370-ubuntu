#!/bin/bash
set -euo pipefail
WS=/root/rmx3370-ubuntu
BASE_TAR="$WS/out/downloads/ubuntu-base-24.04.5-base-arm64.tar.gz"
ROOTFS="$WS/out/rootfs-noble-arm64"
OUT_TAR="$WS/out/ubuntu-24.04.5-bitra-server-arm64.tar.gz"
AUTH_KEYS="${AUTH_KEYS:-$WS/private/authorized_keys}"
KERNEL_DEB=$(ls -1 "$WS/out/debs"/linux-image-*-bitra*_arm64.deb | sort -V | tail -n1)
SUPP_DEB=$(ls -1 "$WS/out/debs"/bitra-device-support_*_arm64.deb | sort -V | tail -n1)

[ -f "$BASE_TAR" ] || { echo "Missing $BASE_TAR" >&2; exit 1; }
[ -f "$KERNEL_DEB" ] || { echo "Missing kernel deb" >&2; exit 1; }
[ -f "$SUPP_DEB" ] || { echo "Missing device-support deb" >&2; exit 1; }
[ -f "$AUTH_KEYS" ] || { echo "Missing $AUTH_KEYS" >&2; exit 1; }

cleanup() {
  for m in dev/pts dev sys proc; do
    mountpoint -q "$ROOTFS/$m" && umount -lf "$ROOTFS/$m" || true
  done
}
trap cleanup EXIT

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
tar -xzpf "$BASE_TAR" -C "$ROOTFS"

cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
cp "$KERNEL_DEB" "$SUPP_DEB" "$ROOTFS/tmp/"

cat > "$ROOTFS/tmp/chroot_setup.sh" << 'CHROOT_EOF'
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

echo "rmx3370-ubuntu" > /etc/hostname
cat > /etc/hosts << 'H'
127.0.0.1 localhost
127.0.1.1 rmx3370-ubuntu
::1 localhost ip6-localhost ip6-loopback
H

cat > /etc/fstab << 'F'
LABEL=ubuntu-root / ext4 defaults,noatime,errors=remount-ro 0 1
F

apt-get update
apt-get install -y --no-install-recommends \
  systemd systemd-sysv dbus udev kmod initramfs-tools \
  openssh-server sudo ca-certificates curl wget \
  iproute2 iputils-ping net-tools dnsutils dnsmasq-base \
  network-manager wpasupplicant iw rfkill \
  chrony fake-hwclock zram-tools \
  vim-tiny nano tmux htop less procps psmisc \
  e2fsprogs parted util-linux python3 device-tree-compiler \
  apparmor locales tzdata

locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

if ! id ubuntu >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,adm,dialout,plugdev,netdev ubuntu
  passwd -l ubuntu
  echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu-nopasswd
  chmod 440 /etc/sudoers.d/90-ubuntu-nopasswd
fi

# Prevent dnsmasq from competing globally (we spawn dedicated dnsmasq on usb0 only)
systemctl disable dnsmasq 2>/dev/null || true

dpkg -i /tmp/bitra-device-support_*.deb
dpkg -i /tmp/linux-image-*-bitra*.deb

# Configure initramfs-tools MODULES=most + gzip so UFS/ext4/SMMU work reliably
KREL=$(ls -1 /boot/vmlinuz-*-bitra* | sort -V | tail -n1 | sed "s|.*/vmlinuz-||")
sed -i 's/^COMPRESS=.*/COMPRESS=gzip/' /etc/initramfs-tools/initramfs.conf || true
update-initramfs -c -k "$KREL"
ls -lh "/boot/initrd.img-$KREL"

# Generate SSH host keys now so first boot is instant
dpkg-reconfigure -f noninteractive openssh-server || ssh-keygen -A

systemctl enable ssh NetworkManager chrony fake-hwclock bitra-usb-gadget.service || true

rm -f /tmp/*.deb /tmp/chroot_setup.sh
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT_EOF
chmod +x "$ROOTFS/tmp/chroot_setup.sh"

mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"

chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /bin/bash /tmp/chroot_setup.sh

# Install user SSH public key (key-only auth; never committed to repo)
install -d -m 700 "$ROOTFS/root/.ssh" "$ROOTFS/home/ubuntu/.ssh"
install -m 600 "$AUTH_KEYS" "$ROOTFS/root/.ssh/authorized_keys"
install -m 600 "$AUTH_KEYS" "$ROOTFS/home/ubuntu/.ssh/authorized_keys"
chroot "$ROOTFS" /usr/bin/qemu-aarch64-static /usr/bin/chown -R ubuntu:ubuntu /home/ubuntu/.ssh

KREL=$(ls -1 "$ROOTFS/boot"/vmlinuz-*-bitra* | sort -V | tail -n1 | sed "s|.*/vmlinuz-||")
cp "$ROOTFS/boot/initrd.img-$KREL" "$WS/out/initrd.img-$KREL"

rm -f "$ROOTFS/usr/bin/qemu-aarch64-static"
# Keep clean static DNS fallback until NetworkManager writes /etc/resolv.conf
rm -f "$ROOTFS/etc/resolv.conf"
cat > "$ROOTFS/etc/resolv.conf" << 'DNS'
nameserver 223.5.5.5
nameserver 1.1.1.1
DNS

cleanup
trap - EXIT

echo "[rootfs] Packing $OUT_TAR ..."
tar --numeric-owner -czpf "$OUT_TAR" -C "$ROOTFS" .
sha256sum "$OUT_TAR" > "$OUT_TAR.sha256"
ls -lh "$OUT_TAR" "$WS/out/initrd.img-$KREL"
