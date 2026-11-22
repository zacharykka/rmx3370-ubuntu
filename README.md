# realme GT Neo 2 (`RMX3370` / `bitra`) — Mainline Linux + Ubuntu 24.04 LTS Server

Clean, reproducible mainline Linux (`7.4.0-rc3`) and **Ubuntu 24.04.5 LTS Server (ARM64)** port for turning an unlocked **realme GT Neo 2 (`RMX3370`, Qualcomm SM8250-AC / Snapdragon 870, 12 GiB RAM, 256 GiB UFS 3.1)** into a quiet, low-power, 24/7 headless ARM64 mobile server with built-in UPS battery protection.

## Documentation
- **[Build, Package & Flash Guide](docs/build-and-flash.md)** — Complete step-by-step instructions from upstream Linux source to cold-booting Ubuntu 24.04.5 LTS Server, Wi-Fi 6 setup, anti-swelling charge control, and recovery.
- **[Bring-Up Pitfalls & Debugging Notes](docs/pitfalls-and-debugging.md)** — Every real RMX3370 hardware/bootloader/initramfs pitfall hit during development (with root causes, `pstore` evidence, and exact fixes).
- **[Hardware & Milestone Status](docs/status.md)** — Live bring-up checklist and verified hardware capabilities.
- **[Kernel ABI Ledger](docs/kernel-abi.md)** — Packaged kernel release history (`-bitra1` .. `-bitra11`).
- **[Technical Debt Tracker](docs/tech-debt.md)** — Known temporary workarounds and exit criteria.

## Verified Working Hardware (`7.4.0-rc3-bitra11` + `bitra-device-support 1.0`)

| Subsystem | Hardware / Driver | Status | Notes |
|---|---|---|---|
| SoC / CPU / CPUfreq | SM8250-AC 8x Kryo 485 (`qcom-cpufreq-hw`) | **Working** | 3 clusters (`0.30–1.80`, `0.71–2.42`, `0.84–3.19 GHz`), 25 thermal zones, zero boot-crutch cmdline flags |
| RAM & Swap | 12 GiB LPDDR5 + `zram0` (LZ4) | **Working** | Exact 22-region RMX3370 `reserved-memory` map |
| Storage | Samsung UFS 3.1 (`1d84000.ufshc`) | **Working** | All 6 LUNs (`sda`–`sdf`); `/dev/sda11` (`222 GiB` ext4 `LABEL=ubuntu-root`), GPT untouched |
| USB Management Net | `a600000.usb` CDC-ECM (`usb0`) | **Working** | Static `192.168.2.15/24` + `dnsmasq` DHCP without default-route hijack; native on macOS/Linux |
| Wi-Fi 6 | Qualcomm `QCA6390` (`ath11k_pci` over PCIe0) | **Working** | 2.4/5 GHz 802.11ax HE via `NetworkManager`; deterministic MAC udev rule; device-local firmware |
| Battery Fuel Gauge | `TI BQ28Z610` (`bq27xxx`, `i2c16@0x55`) | **Working** | 2S pack voltage (~7.4–8.8 V), current, SOC, cycle count, temperature |
| 2S Charger & Anti-Swelling | `MPS MP2650` (`mp2650_charger`, `i2c5@0x5c`) | **Working** | Upstream `charge_behaviour` (`auto`, `inhibit-charge` USB bypass, `force-discharge` HIZ) + 60s systemd timer (`55%–75%` band) |
| Native OLED Display & Anti-Burn-In | Samsung `AMS662ZS01` (`panel-samsung-ams662zs01`, `1080x2400 @ 60 Hz`, DSC 1.1) | **Working** | Native DSI command-mode OLED + 12-bit DCS backlight (`0..2047`) + true DPMS power-off (`bitra-oled-blank.service` auto-blanks on headless boot) |
| GPU (3D / Vulkan) | Qualcomm `Adreno 650` (`msm` + `GMU` + `freedreno` / `Turnip`) | **Working** | Mesa OpenGL 4.6 / ES 3.2 (`FD650`) + Vulkan (`Turnip`); uses stock device-signed `a650_zap.mbn` + upstream `a650_sqe.fw`/`a650_gmu.bin` |
| Touchscreen | `Synaptics S3908` (`synaptics_tcm_i2c`, `i2c13@0x4b`) | **Working** | Native TouchComm v1 I2C driver, 10-finger multitouch (`8639x19199` subpixel native) |
| Hardware Buttons | Power (`pm8941_pwrkey`), Volume Up/Down (`pm8150` GPIO 6/7) | **Working** | All three physical side buttons report standard Linux input keycodes |
| Optional Touch Desktop | `Phosh` + `phoc` Wayland (`bitra-desktop`) | **Working (Optional)** | Headless `multi-user.target` by default; start/stop on demand via `sudo bitra-desktop start` / `stop` |
| Ubuntu Server Stack | Ubuntu 24.04.5 LTS ARM64 | **Working** | `systemd running` (0 failed units), key-only SSH, Docker (`overlayfs`, `cgroup2fs`, `iptables-nft` NAT/bridge), AppArmor, `wireguard`, `nf_tables` |
| USB Host / OTG | `pm8150b_typec` + `usb_1_dwc3` OTG + MP2650 5V boost | **Working** | Dual-role Type-C + 5V/1.25A OTG boost; verified with external USB hard drive |
| Built-in 5G Modem + SMS + 5G Data | `SDX55M` (PCIe2 MHI + Sahara + EFS Sync + `tqftpserv-sdx55` + QMI-over-QRTR + `rmnet` + `ModemManager`) | **Working** | Cold-boots AMSS (~16s), continuous local EFS sync (raw UFS untouched), live SMS (`mmcli`) **and live 5G NR SA cellular internet** (`bitra-wwan` over `rmnet_data0@mhi_hwip0`, Dual-SIM DSDS supported) |

## ⚠️ Required Proprietary Files Extracted From Official Stock Images / Device Partitions

**Because this repository contains zero proprietary OEM blobs, EFS data, or device-unique partitions, you MUST extract the following files from your own RMX3370 official stock ROM (`*.img`) or device UFS partitions (read-only):**

| Target Feature | **Required Files to Extract (from Official Stock IMG / Device)** | **Source Partition / Official IMG** | **Destination Path** |
|---|---|---|---|
| **Bootloader DTBO Sink (Required to Boot)** | **`bitra_dtbo_0.dtbo`** (DTBO entry `0`, dumped via `mkdtimg dump dtbo.img -b bitra_dtbo_`) | **Stock `dtbo` partition / official `dtbo.img`** | `private/stock/bitra_dtbo_0.dtbo` (build host) |
| **Wi-Fi 6 (`QCA6390`)** | **`amss20.bin` (rename to `amss.bin`)**, **`m3.bin`** | **Stock `modem` partition / official `NON-HLOS.bin`** (`image/`) | `/lib/firmware/updates/ath11k/QCA6390/hw2.0/` |
| **Wi-Fi 6 Board Calibration** | **`bdwlan.elf` (rename to `board.bin`)** | **Device-own `persist` partition (`/dev/sda2`, read-only)** | `/lib/firmware/updates/ath11k/QCA6390/hw2.0/board.bin` |
| **Built-in 5G Modem (`SDX55M`)** | **Entire `image/sdx55m/` directory** (**`sbl1.mbn`, `qdsp6sw.mbn`, `apps.mbn`, `aop.mbn`, `tz.mbn`, `hyp.mbn`, `acdb.mbn`, `multi_image.mbn`, `multi_image_qti.mbn`, `xbl_cfg.elf`, `apdp.mbn`, `devcfg.mbn`, `sec.elf`**) | **Stock `modem` partition / official `NON-HLOS.bin`** (`image/sdx55m/`) | `/lib/firmware/updates/qcom/sdx55m/` |
| **5G Modem Carrier Configs (MCFG)** | **Entire `image/modem_pr/` directory** (served over QRTR TFTP by `tqftpserv-sdx55`) | **Stock `modem` partition / official `NON-HLOS.bin`** (`image/modem_pr/`) | `/lib/firmware/modem_pr/` |
| **5G Modem Read-Only EFS Snapshot** | **Device-unique `mdm1m9kefs1`, `mdm1m9kefs2`, `mdm1m9kefs3`, `mdmddr`** (**MUST be dumped read-only from YOUR OWN phone; NEVER share or overwrite raw UFS EFS!**) | **Device UFS `/dev/disk/by-partlabel/mdm1m9kefs{1,2,3}` & `mdmddr`** | `/var/lib/bitra/sdx55m-efs/` (via `sudo bitra-extract-sdx55-fw`) |
| **Stock Rollback Backup (Strongly Recommended)** | **Original `boot.img`, `dtbo.img`, `persist.img`, `mdm1m9kefs1/2/3`** | **Your device before flashing** | Safe external backup on host |

> **Pre-Extracted Generic Stock Firmware Pack (GitHub Release)**: To save time, the **generic (non-device-unique)** stock files (`bitra_dtbo_0.dtbo`, QCA6390 Wi-Fi 6 firmware, SDX55M `sdx55m/*`, and `modem_pr/*`) are also attached to the **[`firmware-rmx3370-stock` GitHub Release](https://github.com/zacharykka/rmx3370-ubuntu/releases/tag/firmware-rmx3370-stock)** (`rmx3370-stock-firmware-generic.tar.xz`). **Device-unique EFS partitions (`mdm1m9kefs1/2/3`, `mdmddr`) contain your phone's personal IMEI and are STRICTLY EXCLUDED — you must always extract them read-only from your own phone via `sudo bitra-extract-sdx55-fw`.**

> **One-Command On-Device Modem Extraction**: Once Ubuntu is running on the phone, **`sudo bitra-extract-sdx55-fw`** automatically mounts the `modem` partition **read-only** and safely extracts **`sdx55m/`**, **`modem_pr/`**, and the read-only **`mdm1m9kefs{1,2,3}` + `mdmddr`** snapshots (runtime EFS syncs write only to `/var/lib/bitra/sdx55m-efs-rw/` and never touch raw UFS).

## Quick Operations Reference (After Flashing)
```bash
# Connect over USB CDC-ECM (key-only SSH; password auth is disabled)
ssh ubuntu@192.168.2.15

# Connect to Wi-Fi 6
sudo nmcli dev wifi list
sudo nmcli dev wifi connect "<SSID>" password "<PASSWORD>"

# Check battery, 24/7 anti-swelling charger mode, and OLED power-off state
cat /sys/class/power_supply/bq28z610-0/{capacity,voltage_now,current_now,temp}
cat /sys/class/power_supply/mp2650-charger/{charge_behaviour,voltage_now,current_now}
cat /etc/bitra-charge-limit.conf

# Built-in SDX55M 5G modem (first-time local read-only firmware/EFS extraction)
sudo bitra-extract-sdx55-fw
# Optional: select SIM Slot 2 (e.g. eSIM chip card in slot 2) on boot
echo 'SIM_SLOT="2"' | sudo tee /etc/default/bitra-sdx55
# Check live cellular registration and SMS via ModemManager
mmcli -m 0
mmcli -m 0 --messaging-list-sms

# Built-in 5G/4G cellular internet (QMI over QRTR + rmnet_data0)
sudo bitra-wwan status
sudo bitra-wwan up              # Uses /etc/default/bitra-wwan (default metric 700 = Wi-Fi failover)
sudo bitra-wwan down

# Optional Phosh mobile touch desktop (headless server with OLED off by default)
sudo bitra-desktop status
sudo bitra-desktop start        # Wake OLED & launch Phosh (scale = 2)
sudo bitra-desktop stop         # Stop Phosh & true-DPMS power-off OLED
# Note: set a local password (`sudo passwd ubuntu`) to unlock Phosh's lockscreen; SSH remains strictly key-only.

# Reboot straight into Fastboot without touching physical buttons
sudo reboot bootloader
```

## Repository Layout
- `patches/` — Clean `git format-patch` series (`0001`–`0006`) against upstream Linux `7.4.0-rc3` (`65e4fd942`): `sm8250-realme-bitra.dts`, `mp2650_charger.c`, `panel-samsung-ams662zs01.c`, `synaptics_tcm_i2c.c`, `ubwc_config.c`, and SDX55M MHI support.
- `kernel-cfg/` — Kernel config fragments (`00-base-sm8250-ram.config`, `10-bitra-server.config`).
- `tools/` — Reproducible build, `.deb` packaging (`linux-image-*.deb`, `bitra-device-support_*.deb`), rootfs assembly, offline DTBO sink injection, and `boot_v2` + AVB hash footer scripts.
- `docs/` — Build/flash guide, bring-up pitfalls, status ledger, kernel ABI ledger, and tech-debt tracker.

> **Privacy & Licensing Hygiene**: No OEM firmware blobs, EFS/persist backups, MAC addresses, or SSH keys are stored in this repository. QCA6390 firmware (`amss.bin`, `m3.bin`, `board.bin`) is extracted locally read-only from the device's own `modem`/`persist` partitions. Integration scripts and docs are MIT-licensed; kernel patches carry their own `GPL-2.0-only` / `BSD-3-Clause` SPDX headers; `tools/avbtool.py` is Apache-2.0 (from AOSP).
