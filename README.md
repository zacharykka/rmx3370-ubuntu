# realme GT Neo 2 (`RMX3370` / `bitra`) — Mainline Linux + Ubuntu 24.04 LTS Server

Clean, reproducible mainline Linux (`7.4.0-rc3`) and **Ubuntu 24.04.5 LTS Server (ARM64)** port for turning an unlocked **realme GT Neo 2 (`RMX3370`, Qualcomm SM8250-AC, 12 GiB RAM, 256 GiB UFS 3.1)** into a 24/7 headless mobile ARM64 server.

## Verified Working Hardware (`7.4.0-rc3-bitra4`, Flashed & Cold-Boot Verified)
- **SoC / CPU / Thermal**: 8x Kryo 485 CPUs + EPSS HW CPUfreq + 25 thermal zones (`tsens0`/`tsens1` + PMIC), **zero boot-crutch cmdline flags** (no `clk_ignore_unused`, `pd_ignore_unused`, `regulator_ignore_unused`, or `iommu.passthrough=1`)
- **Storage & Memory**: 12 GiB RAM + 256 MiB LZ4 `zram` swap; 222 GiB UFS 3.1 ext4 rootfs on `/dev/sda11` (GPT untouched)
- **Offline DTBO Sink Gate**: `tools/inject_dtbo_sink.py` verified against both `fdtoverlay` and AOSP `libufdt` so stock `dtbo` applies cleanly without modifying stock `dtbo`
- **USB Management Net & SSH**: USB CDC-ECM (`usb0`, `192.168.2.15/24`, DHCP without default-route hijack), key-only OpenSSH (`PasswordAuthentication no`), Docker/Podman ready (`cgroup2fs`, `overlay`, `nf_tables`, `wireguard`, AppArmor)
- **Wi-Fi 6 (`QCA6390` `ath11k_pci`)**: PCIe0 Gen2 x1 + `qca6390-pmu`, 2.4/5 GHz 802.11ax HE via `NetworkManager`, persistent MAC udev rule when OTP MAC is zero
- **Battery Fuel Gauge (`TI BQ28Z610`)**: `i2c16@0x55` (`bq27xxx`), live 2S pack voltage/current/SOC/cycles/temp
- **2S Charger + 24/7 Anti-Swelling Control (`MPS MP2650`)**: Clean mainline `drivers/power/supply/mp2650_charger.c` on `i2c5@0x5c` with upstream `charge_behaviour` (`auto`, `inhibit-charge` USB bypass, `force-discharge` HIZ) + `bitra-charge-limit.timer` maintaining battery in `55%-75%`
- **True Hardware OLED Power-Off**: RPMh regulator cleanup (`vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15`) physically powers off the OLED panel at boot (~1.5 W total system idle power, zero burn-in)

## Repository Layout
- `patches/` — Mainline Linux `7.4.0-rc3` (`65e4fd942`) patches (`sm8250-realme-bitra.dts` + `mp2650_charger.c`); apply with `git am patches/*.patch`
- `kernel-cfg/` — Kernel config fragments (`10-bitra-server.config`)
- `tools/` — Reproducible build, `.deb` packaging (`linux-image-*.deb`, `bitra-device-support_*.deb`), rootfs assembly, and `boot_v2` + AVB hash footer scripts
- `docs/` — [status.md](docs/status.md), [kernel-abi.md](docs/kernel-abi.md), [tech-debt.md](docs/tech-debt.md)

> **Privacy & Licensing Hygiene**: No OEM firmware blobs, EFS/persist backups, device MAC addresses, or SSH keys are stored in this repository. QCA6390 firmware (`amss.bin`, `m3.bin`, `board.bin`) is extracted locally read-only from the device's own `modem`/`persist` partitions into `/lib/firmware/updates/ath11k/QCA6390/hw2.0/`.
