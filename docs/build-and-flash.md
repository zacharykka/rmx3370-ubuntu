# Build, Package & Flash Guide (`RMX3370` / `bitra`)

This guide walks through reproducing the mainline Linux `7.4.0-rc3` kernel, packaging the `.deb` files, assembling the Ubuntu 24.04.5 LTS Server (ARM64) rootfs, testing safely from RAM via `fastboot boot`, and flashing `boot`.

> **Safety Warning**: Back up your stock partitions (especially `boot`, `dtbo`, `persist`, and modem EFS partitions `mdm1m9kefs1/2/3`) to an external host before flashing anything. This port uses an **A-only** layout, does **not** touch the GPT partition table or `dtbo`, and formats **only** `/dev/sda11` (`userdata`, ~226.5 GiB) as `ext4`.

---

## 1. Prerequisites

### Build Host (x86_64 Linux / WSL2 recommended)
```bash
sudo apt update
sudo apt install -y \
  build-essential bc bison flex libssl-dev libelf-dev dwarves \
  gcc-aarch64-linux-gnu ccache device-tree-compiler \
  qemu-user-static debootstrap dpkg-dev python3 curl wget xz-utils cpio gzip
```
You also need `mkbootimg` (AOSP `mkbootimg` installed at `/usr/local/bin/mkbootimg`). `tools/avbtool.py` is included in this repository.

### Host Connected to the Phone (macOS / Linux)
- `android-platform-tools` (`fastboot`)
- An SSH keypair (e.g. `~/.ssh/id_ed25519.pub`)

---

## 2. Clone Upstream Linux & Apply Patches

Check `patches/BASE.txt` for the exact base commit (`65e4fd942`, Linux `7.4.0-rc3`):

```bash
git clone https://github.com/zacharykka/rmx3370-ubuntu.git
cd rmx3370-ubuntu

# Clone upstream Linux into ./kernel (gitignored)
git clone --depth=200 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git kernel
cd kernel
git checkout -b rmx3370-mainline 65e4fd942
git am ../patches/*.patch
cd ..
```

---

## 3. Stage Device-Local Inputs (Never Committed to Git)

All device-specific files live under `private/` (gitignored):

1. **Stock DTBO (`private/stock/bitra_dtbo_0.dtbo`)**:
   Extract entry `0` from your phone's stock `dtbo.img` (using `mkdtimg dump dtbo.img -b bitra_dtbo_`). Our offline DTBO sink tool (`tools/inject_dtbo_sink.py`) reads `__fixups__` from this file so the stock bootloader (`ABL`) can apply the stock `dtbo` partition onto our mainline DTB without errors or modifying the `dtbo` partition.
2. **SSH Public Key (`private/authorized_keys`)**:
   ```bash
   mkdir -p private/stock
   cp ~/.ssh/id_ed25519.pub private/authorized_keys
   ```

---

## 4. Build the Kernel & `.deb` Packages

### 4.1 Configure & Compile Mainline Kernel
```bash
OUT="$PWD/out/server-build"
mkdir -p "$OUT"

# Start from upstream defconfig + server config fragment
make -C kernel O="$OUT" ARCH=arm64 defconfig
(cd kernel && ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" ../kernel-cfg/10-bitra-server.config)
make -C kernel O="$OUT" ARCH=arm64 LOCALVERSION="" olddefconfig
make -C kernel O="$OUT" ARCH=arm64 LOCALVERSION="" prepare

# IMPORTANT: Always pass LOCALVERSION="" so git-ahead HEAD does NOT append a "+" suffix to vermagic!
make -j$(nproc) -C kernel O="$OUT" ARCH=arm64 LOCALVERSION="" \
  CROSS_COMPILE="ccache aarch64-linux-gnu-" \
  Image qcom/sm8250-realme-bitra.dtb modules
```

### 4.2 Build `.deb` Packages
```bash
# Kernel + modules + DTB package -> out/debs/linux-image-7.4.0-rc3-bitra4_1_arm64.deb
OUT="$PWD/out/server-build" bash tools/pkg_kernel_deb.sh

# Device integration package -> out/debs/bitra-device-support_0.3_arm64.deb
# Includes: USB CDC-ECM service, key-only SSH config, NetworkManager usb0 unmanaged rule,
#           compact initramfs-tools config (MODULES=list), Wi-Fi MAC udev rule,
#           24/7 anti-swelling charge-limit systemd timer, 24/7 no-suspend policy
bash tools/pkg_device_support_deb.sh 0.3
```

---

## 5. Assemble Ubuntu 24.04.5 LTS Server Rootfs & `boot.img`

```bash
# Downloads & SHA256-verifies official ubuntu-base-24.04.5-base-arm64.tar.gz,
# installs server packages + our two .debs via qemu-aarch64-static chroot,
# generates compact initrd (< 8 MiB), and outputs:
#   out/ubuntu-24.04.5-bitra-server-arm64.tar.gz
#   out/initrd.img-7.4.0-rc3-bitra4
bash tools/build_ubuntu_rootfs.sh

# Injects DTBO sink symbols, verifies offline fdtoverlay apply, checks initrd <= 14 MiB,
# builds Android boot_v2 image, and appends 96 MiB AVB hash footer:
#   out/boot-bitra-ubuntu-7.4.0-rc3-bitra4.img
OUT="$PWD/out/server-build" bash tools/make_ubuntu_boot.sh
```

> **Note on `initrd` size**: `boot_v2` places the ramdisk at `0x01000000` and DTB at `0x01f00000` (a **15.0 MiB** window). `bitra-device-support` configures `/etc/initramfs-tools/conf.d/10-bitra.conf` with `MODULES=list` (all boot-critical UFS/ext4/SMMU/RPMh/USB drivers are built-in `=y`), keeping `initrd` around **7.4 MiB**. `tools/make_ubuntu_boot.sh` enforces a hard **14 MiB** limit to prevent ramdisk/DTB overlap.

---

## 6. First-Time Installation onto `/dev/sda11`

### 6.1 Boot the RAM Maintenance Image
Build the minimal BusyBox + `e2fsprogs` RAM maintenance image (`boot-bitra-maint.img`), enter Fastboot (`Power + Volume Down`), and boot it from RAM (does not modify any partition):

```bash
fastboot -s <SERIAL> boot boot-bitra-maint.img
```

Wait ~12 seconds for USB CDC-ECM (`192.168.2.15`) to come up, then connect via `telnet 192.168.2.15 23`.

### 6.2 Format `/dev/sda11` and Stream Rootfs Over HTTP + SHA256
> **Do not stream rootfs tarballs over raw `nc`**, as TCP half-close can silently truncate the last few hundred KiB. Always serve over HTTP (`Content-Length`) and verify `sha256sum` before extracting.

On your host machine (in the directory holding `ubuntu-24.04.5-bitra-server-arm64.tar.gz`):
```bash
python3 -m http.server 18888 --bind 0.0.0.0
```

Inside the phone's maintenance telnet shell (all block devices start read-only for safety):
```sh
# Unlock ONLY sda / sda11
blockdev --setrw /dev/sda && blockdev --setrw /dev/sda11

# Format userdata (/dev/sda11) as ext4 with label ubuntu-root
/sbin/mke2fs -t ext4 -F -L ubuntu-root /dev/sda11
mount -t ext4 /dev/sda11 /mnt

# Download over USB ECM (~35s for 151 MiB) and verify SHA256
wget -O /mnt/rootfs.tar.gz http://<HOST_USB_IP>:18888/ubuntu-24.04.5-bitra-server-arm64.tar.gz
sha256sum /mnt/rootfs.tar.gz   # MUST match ubuntu-24.04.5-bitra-server-arm64.tar.gz.sha256!

# Extract, clean up, and fsck
tar -xzpf /mnt/rootfs.tar.gz -C /mnt
rm -f /mnt/rootfs.tar.gz
sync && umount /mnt
/sbin/e2fsck -fy /dev/sda11

# Reboot cleanly straight back into Fastboot
mount -o ro /dev/sda11 /mnt
chroot /mnt /usr/bin/python3 -c 'import ctypes; ctypes.CDLL("libc.so.6").syscall(142, 0xfee1dead, 672274793, 0xa1b2c3d4, b"bootloader")'
```

---

## 7. RAM Smoke Test, Flash `boot`, and Stage Wi-Fi 6 Firmware

### 7.1 Always RAM-Test Before Flashing
```bash
fastboot -s <SERIAL> boot boot-bitra-ubuntu-7.4.0-rc3-bitra4.img
```
Wait ~20–25 seconds, then SSH in:
```bash
ssh ubuntu@192.168.2.15
uname -a                    # 7.4.0-rc3-bitra4 aarch64
systemctl is-system-running # running (0 failed units)
df -h /                     # /dev/sda11 ~222G
```

### 7.2 Extract Device-Own QCA6390 Wi-Fi 6 Firmware (Read-Only, Local Only)
On the phone over SSH:
```bash
sudo mkdir -p /tmp/ro_persist /tmp/ro_modem /lib/firmware/updates/ath11k/QCA6390/hw2.0
sudo mount -o ro /dev/sda2 /tmp/ro_persist
sudo mount -o ro /dev/sde4 /tmp/ro_modem
sudo cp -f /tmp/ro_modem/image/amss20.bin /lib/firmware/updates/ath11k/QCA6390/hw2.0/amss.bin
sudo cp -f /tmp/ro_modem/image/m3.bin     /lib/firmware/updates/ath11k/QCA6390/hw2.0/m3.bin
sudo cp -f /tmp/ro_persist/bdwlan.elf     /lib/firmware/updates/ath11k/QCA6390/hw2.0/board.bin
sudo chmod 644 /lib/firmware/updates/ath11k/QCA6390/hw2.0/*
sudo umount /tmp/ro_persist /tmp/ro_modem
```

### 7.3 Flash `boot` Partition & Verify Cold Boot
```bash
# On the phone (reboots straight into Fastboot, no buttons needed):
sudo reboot bootloader

# On your host:
fastboot -s <SERIAL> flash boot boot-bitra-ubuntu-7.4.0-rc3-bitra4.img
fastboot -s <SERIAL> reboot
```
After ~25 seconds, cold-boot SSH (`ssh ubuntu@192.168.2.15`) is live; after ~32 seconds, `regulator_late_cleanup` powers off the OLED rails (`vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15` -> `disabled`).

---

## 8. Upgrading the Kernel Later (Zero-Risk Workflow)

1. Bump `CONFIG_LOCALVERSION="-bitraN"` in `kernel-cfg/10-bitra-server.config` and record it in `docs/kernel-abi.md`.
2. Build `linux-image-7.4.0-rc3-bitraN_1_arm64.deb` and `boot-bitra-ubuntu-7.4.0-rc3-bitraN.img`.
3. Copy the `.deb` to the phone and install it (`sudo dpkg -i ... && sudo depmod -a 7.4.0-rc3-bitraN`). This keeps the previous working kernel in `/lib/modules` and leaves the `boot` partition untouched.
4. Run `sudo reboot bootloader` and RAM-test via `fastboot boot boot-bitra-ubuntu-7.4.0-rc3-bitraN.img`.
5. Only after verifying all peripherals pass, run `sudo reboot bootloader` and `fastboot flash boot ...`.

---

## 9. Tuning 24/7 Anti-Swelling Charge Control

Edit `/etc/bitra-charge-limit.conf` on the phone:
```ini
ENABLED=1
LOW_PCT=55          # Resume normal charging (auto) when SOC <= 55%
HIGH_PCT=75         # Switch to USB bypass (inhibit-charge) when SOC >= 75%
DRAIN_ABOVE_PCT=80  # Switch to HIZ discharge (force-discharge) when SOC >= 80%
```
- Fail-safe: if SOC is unreadable or `< 20%`, the controller always forces `auto` charging.
- You can also inspect or override immediately:
  ```bash
  cat /sys/class/power_supply/mp2650-charger/charge_behaviour
  echo inhibit-charge | sudo tee /sys/class/power_supply/mp2650-charger/charge_behaviour
  ```

---

## 10. Returning to Stock Android (Recovery)

Because GPT, `dtbo`, `persist`, and modem partitions were never modified, returning to stock Android only requires flashing back your backed-up stock `boot.img` and formatting `userdata`:
```bash
fastboot -s <SERIAL> flash boot /path/to/stock/boot.img
fastboot -s <SERIAL> erase userdata
fastboot -s <SERIAL> reboot
```
