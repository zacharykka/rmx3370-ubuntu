# realme GT Neo 2 (`RMX3370` / `bitra`) — Mainline Linux + Ubuntu 24.04 LTS Server

Clean, reproducible mainline Linux (`7.4.0-rc3`) and **Ubuntu 24.04.5 LTS Server (ARM64)** port for turning an unlocked **realme GT Neo 2 (`RMX3370`, Qualcomm SM8250-AC / Snapdragon 870, 12 GiB RAM, 256 GiB UFS 3.1)** into a quiet, low-power, 24/7 headless ARM64 mobile server with built-in UPS battery protection.

## Documentation
- **[Build, Package & Flash Guide](docs/build-and-flash.md)** — Complete step-by-step instructions from upstream Linux source to cold-booting Ubuntu 24.04.5 LTS Server, Wi-Fi 6 setup, anti-swelling charge control, and recovery.
- **[Bring-Up Pitfalls & Debugging Notes](docs/pitfalls-and-debugging.md)** — Every real RMX3370 hardware/bootloader/initramfs pitfall hit during development (with root causes, `pstore` evidence, and exact fixes).
- **[Hardware & Milestone Status](docs/status.md)** — Live bring-up checklist and verified hardware capabilities.
- **[Kernel ABI Ledger](docs/kernel-abi.md)** — Packaged kernel release history (`-bitra1` .. `-bitra4`).
- **[Technical Debt Tracker](docs/tech-debt.md)** — Known temporary workarounds and exit criteria.

## Verified Working Hardware (`7.4.0-rc3-bitra5`, Flashed & Cold-Boot Verified)

| Subsystem | Hardware / Driver | Status | Notes |
|---|---|---|---|
| SoC / CPU / CPUfreq | SM8250-AC 8x Kryo 485 (`qcom-cpufreq-hw`) | **Working** | 3 clusters (`0.30–1.80`, `0.71–2.42`, `0.84–3.19 GHz`), 25 thermal zones, zero boot-crutch cmdline flags |
| RAM & Swap | 12 GiB LPDDR5 + `zram0` (LZ4) | **Working** | Exact 22-region RMX3370 `reserved-memory` map |
| Storage | Samsung UFS 3.1 (`1d84000.ufshc`) | **Working** | All 6 LUNs (`sda`–`sdf`); `/dev/sda11` (`222 GiB` ext4 `LABEL=ubuntu-root`), GPT untouched |
| USB Management Net | `a600000.usb` CDC-ECM (`usb0`) | **Working** | Static `192.168.2.15/24` + `dnsmasq` DHCP without default-route hijack; native on macOS/Linux |
| Wi-Fi 6 | Qualcomm `QCA6390` (`ath11k_pci` over PCIe0) | **Working** | 2.4/5 GHz 802.11ax HE via `NetworkManager`; deterministic MAC udev rule; device-local firmware |
| Battery Fuel Gauge | `TI BQ28Z610` (`bq27xxx`, `i2c16@0x55`) | **Working** | 2S pack voltage (~7.4–8.8 V), current, SOC, cycle count, temperature |
| 2S Charger & Anti-Swelling | `MPS MP2650` (`mp2650_charger`, `i2c5@0x5c`) | **Working** | Upstream `charge_behaviour` (`auto`, `inhibit-charge` USB bypass, `force-discharge` HIZ) + 60s systemd timer (`55%–75%` band) |
| OLED Screen-Off | `vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15` | **Working** | RPMh `regulator_late_cleanup` powers off OLED physically at boot + 31s (~1.5 W idle, 0 burn-in) |
| Ubuntu Server Stack | Ubuntu 24.04.5 LTS ARM64 | **Working** | `systemd running` (0 failed units), key-only SSH, `cgroup2fs`, AppArmor, `wireguard`, `overlay`, `nf_tables` |
| USB Host / OTG | `pm8150b_typec` + `usb_1_dwc3` OTG + MP2650 5V boost | **Working** | Dual-role Type-C + 5V/1.25A OTG boost; verified with external USB hard drive |
| Built-in 5G Modem SMS | `SDX55M` (PCIe2 MHI + `tqftpserv` + ModemManager) | Planned | P1.5 |

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

# Reboot straight into Fastboot without touching physical buttons
sudo reboot bootloader
```

## Repository Layout
- `patches/` — Clean `git format-patch` series against upstream Linux `7.4.0-rc3` (`65e4fd942`): `sm8250-realme-bitra.dts` and `drivers/power/supply/mp2650_charger.c`.
- `kernel-cfg/` — Kernel config fragments (`00-base-sm8250-ram.config`, `10-bitra-server.config`).
- `tools/` — Reproducible build, `.deb` packaging (`linux-image-*.deb`, `bitra-device-support_*.deb`), rootfs assembly, offline DTBO sink injection, and `boot_v2` + AVB hash footer scripts.
- `docs/` — Build/flash guide, bring-up pitfalls, status ledger, kernel ABI ledger, and tech-debt tracker.

> **Privacy & Licensing Hygiene**: No OEM firmware blobs, EFS/persist backups, MAC addresses, or SSH keys are stored in this repository. QCA6390 firmware (`amss.bin`, `m3.bin`, `board.bin`) is extracted locally read-only from the device's own `modem`/`persist` partitions. Integration scripts and docs are MIT-licensed; kernel patches carry their own `GPL-2.0-only` / `BSD-3-Clause` SPDX headers; `tools/avbtool.py` is Apache-2.0 (from AOSP).
