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

## 3. Stage Device-Local Inputs Extracted From Official Stock Images (Never Committed to Git)

> **⚠️ IMPORTANT — What You MUST Extract From Official Stock `*.img` / Device Partitions:**
> This repository intentionally ships **zero** proprietary Qualcomm/realme firmware blobs or device-unique partitions. You must supply these from your own RMX3370 official stock firmware (`dtbo.img`, `NON-HLOS.bin` / `modem`) and your device's own UFS partitions:
> - **At build time (on build host, under gitignored `private/`)**:
>   1. **`private/stock/bitra_dtbo_0.dtbo`** — **Entry `0` extracted from official stock `dtbo.img`** (`mkdtimg dump dtbo.img -b bitra_dtbo_`). Required by `tools/inject_dtbo_sink.py` so ABL applies stock `dtbo` onto our mainline DTB cleanly without modifying the `dtbo` partition.
>   2. **`private/authorized_keys`** — Your SSH public key (password SSH is disabled by default).
> - **At first boot (on the phone, read-only extraction from stock UFS partitions — see Section 7.2 & 7.3)**:
>   3. **QCA6390 Wi-Fi 6 firmware** — **`amss20.bin` (`-> amss.bin`) & `m3.bin`** from stock **`modem` (`NON-HLOS.bin`)**, plus device-own **`bdwlan.elf` (`-> board.bin`)** from **`persist` (`/dev/sda2`)**.
>   4. **SDX55M 5G modem firmware & carrier MCFG** — **Entire `image/sdx55m/*` (`sbl1.mbn`, `qdsp6sw.mbn`, `apps.mbn`, `aop.mbn`, `tz.mbn`, `hyp.mbn`, `acdb.mbn`, `multi_image*.mbn`, `xbl_cfg.elf`, `apdp.mbn`, `devcfg.mbn`, `sec.elf`)** and **`image/modem_pr/*`** from stock **`modem` (`NON-HLOS.bin`)**.
>   5. **Device-unique SDX55M EFS read-only snapshot** — **`mdm1m9kefs1`, `mdm1m9kefs2`, `mdm1m9kefs3`, `mdmddr`** dumped **read-only** from your own phone's UFS partitions via `sudo bitra-extract-sdx55-fw`. (**Never share your EFS files and never write to raw UFS EFS partitions.**)
>   6. **Adreno 650 GPU firmware (for Display / GPU / Phosh)** — **Stock device-signed `firmware/a650_zap.elf` -> `/lib/firmware/qcom/sm8250/realme/bitra/a650_zap.mbn`** from stock **`vendor` (`vendor.img`)**, paired with **upstream `linux-firmware` `qcom/a650_sqe.fw` (`>= v95`, stock Android v93 is rejected by Linux 7.4) & `qcom/a650_gmu.bin`**.
>   7. **QCA6390 Bluetooth 5.2 firmware** — **`image/htbtfw20.tlv` & `image/htnv20.bin`** from stock **`bluetooth` partition (`/dev/sde5`)** -> `/lib/firmware/qca/`.
>   8. **Audio DSP (`ADSP`) firmware** — **`image/adsp.mdt`, `image/adsp.b00`–`adsp.b18`, `image/adspr.jsn`, `image/adspua.jsn`** from stock **`modem` partition (`/dev/sde4` / `NON-HLOS.bin`)** -> `/lib/firmware/qcom/sm8250/realme/bitra/`.

> **Pre-Extracted Generic Stock Firmware & Pre-Built `.deb` Packages (GitHub Releases)**:
> - **[`firmware-rmx3370-stock`](https://github.com/zacharykka/rmx3370-ubuntu/releases/tag/firmware-rmx3370-stock)** (`rmx3370-stock-firmware-generic.tar.zst`): Model-generic stock firmware for QCA6390 Wi-Fi 6 + Bluetooth 5.2, SDX55M 5G modem (`sdx55m/*`, `modem_pr/*`), Adreno 650 GPU, ADSP audio DSP, SLPI sensor DSP + configs, and squashed Qualcomm Venus `venus.mbn`. **Device-unique EFS partitions (`mdm1m9kefs1/2/3`, `mdmddr`) and `/persist/sensors` calibration are STRICTLY EXCLUDED — extract them read-only from your own phone.**
> - **[`debs-7.4.0-rc3-bitra14`](https://github.com/zacharykka/rmx3370-ubuntu/releases/tag/debs-7.4.0-rc3-bitra14)**: Ready-to-install ARM64 `.deb` packages for `linux-image-7.4.0-rc3-bitra14`, `bitra-device-support 1.3`, `hexagonrpc`, `libssc`, and SSC-enabled `iio-sensor-proxy 3.9`.

Stage build-time inputs on your build host:
```bash
mkdir -p private/stock
# 1. Extract bitra_dtbo_0.dtbo from official stock dtbo.img (using AOSP mkdtimg)
mkdtimg dump /path/to/stock/dtbo.img -b private/stock/bitra_dtbo_
# 2. Copy your SSH public key
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
# IMPORTANT: Merge BOTH 00-base-sm8250-ram.config (built-in UFS/PHY/USB/pstore =y) AND 10-bitra-server.config!
(cd kernel && ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" ../kernel-cfg/00-base-sm8250-ram.config ../kernel-cfg/10-bitra-server.config)
make -C kernel O="$OUT" ARCH=arm64 LOCALVERSION="" olddefconfig
make -C kernel O="$OUT" ARCH=arm64 LOCALVERSION="" prepare

# IMPORTANT: Always pass LOCALVERSION="" so git-ahead HEAD does NOT append a "+" suffix to vermagic!
make -j$(nproc) -C kernel O="$OUT" ARCH=arm64 LOCALVERSION="" \
  CROSS_COMPILE="ccache aarch64-linux-gnu-" \
  Image qcom/sm8250-realme-bitra.dtb modules
```

### 4.2 Build `.deb` Packages
```bash
# Kernel + modules + DTB package -> out/debs/linux-image-7.4.0-rc3-bitra14_1_arm64.deb
OUT="$PWD/out/server-build" bash tools/pkg_kernel_deb.sh

# Device integration package -> out/debs/bitra-device-support_1.3_arm64.deb
# Includes: USB CDC-ECM service, key-only SSH config, NetworkManager usb0 unmanaged rule,
#           compact initramfs-tools config (MODULES=list), Wi-Fi MAC udev rule,
#           24/7 anti-swelling charge-limit systemd timer, 24/7 no-suspend policy
bash tools/pkg_device_support_deb.sh 1.1
```

---

## 5. Assemble Ubuntu 24.04.5 LTS Server Rootfs & `boot.img`

```bash
# Downloads & SHA256-verifies official ubuntu-base-24.04.5-base-arm64.tar.gz,
# installs server packages + our two .debs via qemu-aarch64-static chroot,
# generates compact initrd (< 8 MiB), and outputs:
#   out/ubuntu-24.04.5-bitra-server-arm64.tar.gz
#   out/initrd.img-7.4.0-rc3-bitra14
bash tools/build_ubuntu_rootfs.sh

# Injects DTBO sink symbols, verifies offline fdtoverlay apply, checks initrd <= 14 MiB,
# builds Android boot_v2 image, and appends 96 MiB AVB hash footer:
#   out/boot-bitra-ubuntu-7.4.0-rc3-bitra14.img
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
fastboot -s <SERIAL> boot boot-bitra-ubuntu-7.4.0-rc3-bitra14.img
```
Wait ~20–25 seconds, then SSH in:
```bash
ssh ubuntu@192.168.2.15
uname -a                    # 7.4.0-rc3-bitra14 aarch64
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

### 7.2b Extract Device-Own SDX55M 5G Modem Firmware, MCFG & Read-Only EFS Snapshot (Local Only)
On the phone over SSH (requires `modemmanager`, `qrtr-tools`, and `libqrtr-dev` if building `tqftpserv-sdx55` from `tools/tqftpserv-sdx55/`):
```bash
# Install ModemManager & QRTR runtime (if not already installed)
sudo apt update && sudo apt install -y modemmanager qrtr-tools

# Extract SDX55M firmware (image/sdx55m/*), MCFG (image/modem_pr/*),
# and read-only EFS snapshots (mdm1m9kefs1/2/3, mdmddr) from stock UFS partitions:
sudo bitra-extract-sdx55-fw

# Optional: if your active SIM/eSIM is in physical Slot 2, persist slot selection:
echo 'SIM_SLOT="2"' | sudo tee /etc/default/bitra-sdx55

# Verify after reboot:
mmcli -m 0
mmcli -m 0 --messaging-list-sms

# Optional: bring up 5G/4G cellular data over rmnet_data0 (QMI over QRTR)
# Edit /etc/default/bitra-wwan to set WWAN_SLOT (1 or 2) and WWAN_APN (e.g. cmnet / 3gnet / ctnet)
sudo bitra-wwan status
sudo bitra-wwan up
# To auto-connect 5G/4G on every boot (metric 700 = Wi-Fi failover):
sudo systemctl enable bitra-wwan.service
```
> **EFS Safety**: Runtime EFS syncs from SDX55M (`bitra-sdx55-efs-sync.service` over `/dev/wwan0efs0`) are written **only** to `/var/lib/bitra/sdx55m-efs-rw/`. The phone's factory UFS EFS partitions (`/dev/disk/by-partlabel/mdm1m9kefs*`) are **never** written to.

### 7.2c Optional: Adreno 650 GPU Firmware & Phosh Mobile Touch Desktop

The system boots into **headless `multi-user.target`** by default and automatically powers off the OLED (`bitra-oled-blank.service`) to prevent burn-in. To enable hardware-accelerated 3D (`freedreno` / `Turnip`) and on-demand Phosh desktop:

```bash
# 1. Stage GPU firmware:
#    - Stock device-signed a650_zap.elf (from official vendor.img firmware/a650_zap.elf)
#      -> /lib/firmware/qcom/sm8250/realme/bitra/a650_zap.mbn
#    - Upstream linux-firmware a650_sqe.fw (>= v95) and a650_gmu.bin
#      -> /lib/firmware/qcom/a650_sqe.fw and /lib/firmware/qcom/a650_gmu.bin
sudo mkdir -p /lib/firmware/qcom/sm8250/realme/bitra

# 2. Install Phosh mobile shell, Mesa freedreno/Turnip, and CJK fonts
sudo apt update && sudo apt install -y \
  phosh phoc phosh-osk-stub gnome-session-bin gnome-settings-daemon \
  kgx nautilus gnome-control-center fonts-noto-cjk \
  libgl1-mesa-dri mesa-vulkan-drivers mesa-utils vulkan-tools

# Remove GNOME-Shell-only portal backend (prevents 25s D-Bus hang in Phosh; bitra-device-support also ships phosh-portals.conf)
sudo apt-get remove -y xdg-desktop-portal-gnome || true

# Keep headless server default on boot
sudo systemctl set-default multi-user.target
sudo systemctl disable phosh.service

# 3. Set a local password/PIN for unlocking Phosh's lockscreen
#    (SSH remains strictly key-only via /etc/ssh/sshd_config.d/10-bitra-keyonly.conf)
sudo passwd ubuntu

# 4. Launch or stop Phosh on demand (OLED powers off completely on stop)
sudo bitra-desktop start
sudo bitra-desktop status
sudo bitra-desktop stop
```

### 7.2d Bluetooth 5.2 (`QCA6390`) & Stereo Speakers / Internal Microphones (`ADSP` + `TFA9874` + `WCD9380`)

On the phone over SSH:
```bash
# 1. Install BlueZ, PipeWire Bluetooth plugin, Qualcomm PD-Mapper, and ALSA UCM2 tools
sudo apt update && sudo apt install -y \
  bluez libspa-0.2-bluetooth protection-domain-mapper alsa-utils alsa-ucm-conf libcanberra-pulse

# 2. Extract Bluetooth & ADSP firmware read-only from stock UFS partitions
sudo mkdir -p /tmp/ro_bt /tmp/ro_modem /lib/firmware/qca /lib/firmware/qcom/sm8250/realme/bitra
sudo mount -o ro /dev/sde5 /tmp/ro_bt
sudo cp -f /tmp/ro_bt/image/htbtfw20.tlv /tmp/ro_bt/image/htnv20.bin /lib/firmware/qca/
sudo umount /tmp/ro_bt

sudo mount -o ro /dev/sde4 /tmp/ro_modem
sudo cp -f /tmp/ro_modem/image/adsp.mdt /tmp/ro_modem/image/adsp.b* \
           /tmp/ro_modem/image/adspr.jsn /tmp/ro_modem/image/adspua.jsn \
           /lib/firmware/qcom/sm8250/realme/bitra/
sudo umount /tmp/ro_modem
sudo chmod 644 /lib/firmware/qca/ht* /lib/firmware/qcom/sm8250/realme/bitra/adsp*

# 3. Ensure user belongs to audio/bluetooth groups and enable services
sudo usermod -aG audio,bluetooth ubuntu
sudo systemctl enable pd-mapper.service bluetooth.service bitra-bt-addr.service

# 4. Verify after booting bitra14 + bitra-device-support 1.3:
hciconfig -a
bluetoothctl show
wpctl status    # Shows Stereo Speakers (Dual TFA9874) + Internal Microphones (WCD9380)
```


### 7.2e Linear Haptics (`AW8697`) & SLPI Sensors (`hexagonrpcd` + `libssc` + `iio-sensor-proxy`)

1. **Linear Haptics (`AW8697`)**: Works out-of-the-box on `7.4.0-rc3-bitra14` + `bitra-device-support 1.3`. Install `feedbackd` (and optionally `joystick` for `fftest`) so Phosh/apps trigger tactile feedback via `FEEDBACKD_TYPE=vibra`.
2. **SLPI Firmware & Sensor Configs**:
   - Generic model files (included in `firmware-rmx3370-stock` Release):
     - `/lib/firmware/qcom/sm8250/realme/bitra/slpi.{mdt,b00..b21}`, `slpir.jsn`, `slpius.jsn`
     - `/usr/share/qcom/sm8250/realme/bitra/sensors/{config/*,sns_reg.conf}`
     - `/usr/share/qcom/sm8250/realme/bitra/vendor/lib/rfsa/adsp/libsns_*.so` (with symlink `dsp/sdsp -> /vendor/lib/rfsa/adsp`)
   - **Per-device factory calibration (extract read-only from YOUR OWN phone, never share!)**:
     ```bash
     sudo mkdir -p /mnt/persist_ro /var/lib/bitra/persist-sensors
     sudo mount -o ro /dev/disk/by-partlabel/persist /mnt/persist_ro
     sudo cp -a /mnt/persist_ro/sensors/. /var/lib/bitra/persist-sensors/
     sudo umount /mnt/persist_ro
     sudo ln -sfn /var/lib/bitra/persist-sensors/registry/registry /usr/share/qcom/sm8250/realme/bitra/sensors/registry
     ```
   - **Important**: Do **not** create `/usr/share/qcom/sm8250/realme/bitra/socinfo/` — otherwise SLPI tries to rewrite `temp.json` into the read-only registry and stalls (see Pitfall 39).
3. **Userspace sensor stack**: Download & install the pre-built ARM64 `.deb` packages (`hexagonrpc_0.5.0-bitra1_arm64.deb`, `libssc_0.4.4-bitra1_arm64.deb`, `iio-sensor-proxy_3.9-bitra1_arm64.deb`) from the **[`debs-7.4.0-rc3-bitra14` GitHub Release](https://github.com/zacharykka/rmx3370-ubuntu/releases/tag/debs-7.4.0-rc3-bitra14)** (or build from source with `-Dssc-support=enabled`). `bitra-device-support 1.3` ships `hexagonrpcd-sdsp.service`, `81-bitra-ssc-sensors.rules`, and the `iio-sensor-proxy` ordering drop-in.
4. **Verify**:
   ```bash
   sudo ssccli --sensor accelerometer --timeout 2
   sudo ssccli --sensor magnetometer --timeout 2
   sudo ssccli --sensor light --timeout 2
   sudo timeout 5 monitor-sensor
   ```

### 7.2f Hardware Video Decode/Encode (Qualcomm Venus) & Offline Hardware RTC

1. **Venus VPU Firmware (`venus.mbn`)**: Already included in the **[`firmware-rmx3370-stock`](https://github.com/zacharykka/rmx3370-ubuntu/releases/tag/firmware-rmx3370-stock)** release tarball (`/lib/firmware/qcom/sm8250/realme/bitra/venus.mbn`), or squash it locally from stock `modem` partition (`venus.mdt` + `venus.b00..b10`, `venus.b19`) using `pil-squasher`.
2. **Userspace tools & verification** (`bitra-device-support 1.3` automatically grants `video`/`render` group access to `/dev/video0` & `/dev/video1`):
   ```bash
   sudo apt update && sudo apt install -y ffmpeg v4l-utils gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
   v4l2-ctl --list-devices    # Shows Qualcomm Venus decoder (/dev/video0) + encoder (/dev/video1)

   # 1080p HEVC hardware encode & decode smoke test (~218 fps enc / ~361 fps dec)
   gst-launch-1.0 videotestsrc num-buffers=60 ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 ! v4l2h265enc ! h265parse ! mp4mux ! filesink location=/tmp/test_hevc.mp4
   gst-launch-1.0 filesrc location=/tmp/test_hevc.mp4 ! qtdemux ! h265parse ! v4l2h265dec ! fakesink

   # 1080p H.264 hardware decode via ffmpeg (~224 fps)
   ffmpeg -c:v h264_v4l2m2m -i /tmp/in_h264_1080p.mp4 -f null -
   ```
3. **Offline Hardware RTC (`bitra-rtc-sync`)**: Enabled automatically by `bitra-device-support 1.3` (`bitra-rtc-sync.service` + `bitra-rtc-save.timer`). Verify on boot with `journalctl -b -u bitra-rtc-sync`.

### 7.3 Flash `boot` Partition & Verify Cold Boot
```bash
# On the phone (reboots straight into Fastboot, no buttons needed):
sudo reboot bootloader

# On your host:
fastboot -s <SERIAL> flash boot boot-bitra-ubuntu-7.4.0-rc3-bitra14.img
fastboot -s <SERIAL> reboot
```
After ~25 seconds, cold-boot SSH (`ssh ubuntu@192.168.2.15`) is live and `bitra-oled-blank.service` puts the OLED panel into true DPMS power-off (0 burn-in while headless).

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
