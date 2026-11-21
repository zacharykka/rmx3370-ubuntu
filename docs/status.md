# RMX3370 (realme GT Neo 2 / bitra) Mainline Linux + Ubuntu 24.04 LTS Server Status

- **Device**: realme GT Neo 2 (`RMX3370`, codename `bitra`, OPLUS project `21619` / `0x5473`)
- **SoC**: Qualcomm SM8250-AC (`kona v2.1`), 12 GiB RAM, 256 GiB UFS 3.1 (A-only, `boot` 96 MiB, `userdata` = `/dev/sda11` ~226.5 GiB)
- **Target**: Headless 24/7 ARM64 Ubuntu 24.04.5 LTS Server (single-OS on `sda11`, GPT untouched)
- **Kernel**: Mainline Linux `7.4.0-rc3-bitra5` (`kernel/` branch `rmx3370-mainline`, commit `5f3199e3a`)

## Milestone Status

| Step | Milestone | Status | Notes |
|---|---|---|---|
| 0 | Feasibility assessment & hardware baseline | **Done** | Verified from stock FDT (`live-ours.fdt`), `bound_drivers_v2.txt`, `partitions.txt`; EFS/persist backed up on host |
| 1 | Clean mainline baseline build & offline DTBO sink gate | **Done** | `tools/inject_dtbo_sink.py` verified with both `fdtoverlay` and AOSP `libufdt` (`ufdt_apply_overlay`) |
| 2 | RAM-only debug boot image (`boot_v2` + AVB hash footer) | **Done** | BusyBox initramfs with block-RO safety, CDC-ECM (`192.168.2.15/24`), `udhcpd`, bounded auto-reboot |
| 3 | First mainline RAM boot & zero-crutch Stage-1 bring-up | **Done** | Boots to `/init` in `0.358s`, USB CDC-ECM shell live in `11.2s`, passes **without** `clk_ignore_unused` / `pd_ignore_unused` / `regulator_ignore_unused` / `iommu.passthrough=1` |
| 5 | Persist Ubuntu 24.04.5 LTS Server (ARM64) on `/dev/sda11` | **Done** | Flashed `7.4.0-rc3-bitra1` to `boot` and verified cold boot to key-only SSH in 23s (`systemd running`, 0 failed units, cgroup v2, AppArmor 102 profiles, `wireguard`/`overlay`/`nf_tables`/`zram`) |
| 6.1 | Wi-Fi 6 (`QCA6390` `ath11k_pci`) | **Done (flashed & cold-boot verified)** | PCIe0 Gen2 x1 + `qca6390-pmu` + device-local firmware (`/lib/firmware/updates/ath11k/QCA6390/hw2.0/`) + deterministic MAC udev rule (`99-bitra-wifi-mac.rules`); 2.4/5 GHz 802.11ax HE scan verified via `nmcli` |
| 6.2 | Battery Fuel Gauge (`TI BQ28Z610`) | **Done (flashed & cold-boot verified)** | `i2c16@0x55` (`ti,bq28z610`), live 2S pack telemetry (`8.686 V`, `1904 mAh`, `516` cycles, `30.0 C`) |
| 6.3 | 2S Charger + 24/7 Anti-Swelling Control (`MPS MP2650`) | **Done (flashed & cold-boot verified)** | Clean mainline `drivers/power/supply/mp2650_charger.c` on `i2c5@0x5c` with `charge_behaviour` (`auto`, `inhibit-charge` USB bypass, `force-discharge` HIZ) + `bitra-charge-limit.timer` (`55%–75%` band, drain above `80%`, fail-safe `<20%`) |
| 6.4 | True Hardware OLED Power-Off | **Done (flashed & cold-boot verified)** | `vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15` marked `regulator-boot-on` (no `always-on`) so `regulator_late_cleanup` sends RPMh `ENABLE=0` |
| 6.5 | USB Host/OTG + Type-C + SM8250-AC 3.1872 GHz OPP | **Done (flashed & cold-boot verified; external USB drive tested OK)** | `pm8150b_typec` dual-role + `usb_1_dwc3` `dr_mode=otg` + MP2650 5V OTG VBUS boost regulator + `cpu7` 3.1872 GHz OPP verified live |
| P1.5 | Built-in SDX55M SMS (`mhi_pci_generic` + `tqftpserv` + `ModemManager`) | **Planned** | After Server MVP flash & Wi-Fi validation |
