# Bring-Up Pitfalls & Debugging Notes (`RMX3370` / `bitra`)

A field log of every non-obvious hardware, bootloader, kernel, initramfs, and userspace trap encountered while porting mainline Linux `7.4.0-rc3` + Ubuntu 24.04.5 LTS Server to the realme GT Neo 2 (`RMX3370`), together with the exact root cause and clean fix.

---

## 1. ABL DTB Selection & Stock `dtbo` Overlay Failure
- **Symptom**: Mainline DTB fails to boot in ABL (`fastboot boot` immediately reboots or hangs before kernel entry).
- **Root Cause**: OPLUS SM8250 ABL selects the DTB by `oplus,dtsi_no = <0x5473>` (project `21619`) and unconditionally applies the stock `dtbo` partition onto the chosen DTB using `libufdt`. Stock `dtbo` contains **172 `__fixups__` phandle references** to vendor QCOM nodes that do not exist in mainline DTS; any unresolved symbol aborts overlay application.
- **Fix**:
  - Set `oplus,dtsi_no = <0x5473>` and `qcom,msm-id = <0x164 0x20001>` in `sm8250-realme-bitra.dts`.
  - Run `tools/inject_dtbo_sink.py` during boot image assembly to add missing symbol labels inside a single `/dtbo-sink` container marked **`status = "disabled"`** with **no `compatible` and no `reg`**.
  - Gate every build with both `fdtoverlay` and real AOSP `libufdt` (`ufdt_apply_overlay`) offline before touching the device.
- **Side Effect (`TD-02`)**: Stock `dtbo` overwrites root `/compatible` to `qcom,kona-mtp qcom,kona qcom,mtp` at runtime, which causes a harmless `cpufreq-dt: failed register driver: -17` log because `qcom-cpufreq-hw` already registered.

---

## 2. RMX3370 `reserved-memory` Map Is Shifted by `+0x7a00000`
- **Symptom**: Kernel crashes or silently resets during early boot if inheriting upstream `sm8250.dtsi` `reserved-memory`.
- **Root Cause**: RMX3370's firmware reserves a **205 MiB** `removed_region@80b00000` (`0xcd00000`), shifting all subsequent PIL/tz/modem/adsp regions up by `+0x7a00000` compared to reference `sm8250.dtsi`.
- **Fix**: Replace the entire `reserved-memory` node in `sm8250-realme-bitra.dts` with the exact 22 regions dumped from the device's live runtime FDT (including `ramoops@b0000000` size `0x3ff000` for `pstore` crash logs!).

---

## 3. Instant XPU `PS_HOLD` Reset Inside `deferred_probe_initcall()` (TLMM TZ-Locked GPIOs)
- **Symptom**: Kernel boots cleanly up to `deferred_probe_initcall()`, then suffers an instantaneous hard reset with zero kernel panic or oops.
- **Root Cause**: `f100000.pinctrl` (`&tlmm`) probes GPIO ranges on init. On RMX3370, **QUP SE0 (GPIOs 28–31)** and **QUP SE14 (GPIOs 40–43)** are TrustZone XPU-locked. Reading their TLMM registers triggers an immediate hardware XPU violation (`PS_HOLD` reset).
- **Fix**: Add `gpio-reserved-ranges = <28 4>, <40 4>;` to `&tlmm` in `sm8250-realme-bitra.dts`.

---

## 4. Hang on First CPU Idle (`psci: failed to set PC mode: -3`)
- **Symptom**: Kernel prints `psci: OSI mode supported, failed to set PC mode: -3` and freezes solidly the moment CPU0 enters idle.
- **Root Cause**: Upstream `sm8250.dtsi` enables CPU/cluster PSCI idle states (`idle-states` / `domain-idle-states`) that hang on RMX3370's TrustZone PSCI firmware (stock Android bootargs also pass `lpm_levels.sleep_disabled=1`). Additionally, simply deleting `domain-idle-states` without removing `power-domains = <&cluster_pd>` from `&apps_rsc` and `&cpu0..7` causes `apps_rsc` to **defer forever** because `cpuidle-psci-domain` bails when `pd_count == 0`.
- **Fix**: Delete `idle-states` and `domain-idle-states` AND delete `power-domains` on `&apps_rsc` and `&cpu0..7` (tracked as `TD-01` in `docs/tech-debt.md`).

---

## 5. Interconnect `icc_sync_state` DDR Freeze During Minimal Bring-Up
- **Symptom**: During minimal bisect builds, the kernel hangs right around `late_initcall_sync` / `sync_state()`.
- **Root Cause**: Enabling `mc_virt` / `gem_noc` interconnects while `cpufreq_hw` is disabled causes `icc_sync_state()` to drop DDR bandwidth votes to zero, freezing memory access.
- **Fix**: Keep `cpufreq_hw` and all 10 NOC interconnects enabled together (never ship `clk_ignore_unused` / `pd_ignore_unused`).

---

## 6. OPLUS Phoenix 3-Cold-Reset Recovery Trap (`&scm`)
- **Symptom**: After 3 failed boots while `&scm` was temporarily disabled during bisecting, the phone stopped entering Fastboot/normal boot and booted into stock OPLUS Recovery.
- **Root Cause**: Without `qcom_scm`, Qualcomm resets downgrade from `'warm'` to `'cold'`. OPLUS Phoenix boot-loop protection counts 3 consecutive cold resets and forces official Recovery.
- **Fix**: Always keep `&scm` enabled. Using `qcom_scm` + `pm8150` PON also preserves DRAM for `ramoops@b0000000` (`pstore`) across panics and lets `sudo reboot bootloader` work cleanly from Linux.

---

## 7. USB CDC-ECM DMA, `udhcpd`, and macOS Default-Route Hijack
- **Symptoms**:
  1. `a600000.usb` probes but fails to enumerate on macOS when `apps_smmu` is disabled.
  2. BusyBox `udhcpd` exits silently in RAM initramfs.
  3. On macOS, plugging in USB CDC-ECM breaks the Mac's internet connection.
  4. On Ubuntu, `NetworkManager` strips the static `192.168.2.15/24` IP from `usb0`.
- **Fixes**:
  1. Keep `arm-smmu 15000000.iommu` (`apps_smmu`) enabled (USB descriptor DMA requires SMMU).
  2. Pass explicit `lease_file /tmp/udhcpd.leases` in `udhcpd.conf` (BusyBox fails silently if `/var/lib/misc` is missing).
  3. Pass `--dhcp-option=3 --dhcp-option=6` to `dnsmasq` so DHCP hands the host an IP (`192.168.2.20–30`) with **no default gateway and no DNS**, preventing route hijacking.
  4. Install `/etc/NetworkManager/conf.d/10-bitra-unmanaged-usb0.conf` (`unmanaged-devices=interface-name:usb0`).

---

## 8. `CONFIG_LOCALVERSION_AUTO=n` Still Appending `+` to Kernel Vermagic
- **Symptom**: Even with `# CONFIG_LOCALVERSION_AUTO is not set`, building from a git tree ahead of the `v7.4-rc3` tag produced `7.4.0-rc3-bitra1+`, breaking module matching if packaging assumed `7.4.0-rc3-bitra1`.
- **Fix**: Pass `LOCALVERSION=""` explicitly on every `make` invocation (`scripts/setlocalversion` suppresses `+` when `LOCALVERSION` is defined on the command line).

---

## 9. Raw `nc` Rootfs Streaming Truncates the Tail of the Tarball
- **Symptom**: Streaming `ubuntu-24.04.5-bitra-server-arm64.tar.gz` via raw TCP `nc` consistently dropped the final ~273 KiB (`158334984` vs `158608609` bytes) when macOS closed the socket after `shutdown(SHUT_WR)`.
- **Fix**: Never use raw `nc` for rootfs installation. Serve over HTTP (`python3 -m http.server`, which sends `Content-Length`), download with BusyBox `wget`, and gate extraction on an exact `sha256sum` match.

---

## 10. `boot_v2` Ramdisk / DTB Overlap (`15.0 MiB` Window)
- **Symptom**: First Ubuntu `boot.img` hung silently before userspace.
- **Root Cause**: Stock `boot_v2` offsets put `ramdisk_offset = 0x01000000` (16 MiB) and `dtb_offset = 0x01f00000` (31 MiB), leaving an exact **15.0 MiB (`15,728,640` bytes)** gap. Ubuntu `initramfs-tools` defaults to `MODULES=most`, which bundled 34 MiB of unnecessary `.ko` modules and created a **16.13 MiB** `initrd.img`, overlapping `dtb_offset` by 402 KiB.
- **Fix**: Configure `/etc/initramfs-tools/conf.d/10-bitra.conf` with `MODULES=list` and `COMPRESS=gzip` (all boot-critical drivers are built-in `=y`), shrinking `initrd` to **7.37 MiB**. Added a hard **14 MiB** size guard to both `tools/make_ubuntu_boot.sh` and `bitra-update-bootimg`.

---

## 11. Initramfs `exec run-init ... </dev/console` PID 1 Exit-1 Panic
- **Symptom**: Captured in `/sys/fs/pstore/dmesg-ramoops-0`: kernel booted in `0.84s`, mounted `/dev/sda11` cleanly, and **71 ms later** panicked with `Attempted to kill init! exitcode=0x00000100` (`Comm: init`, NOT `systemd`).
- **Root Cause**: Earlier dmesg printed `Warning: unable to open an initial console.` Because cmdline only specified `console=ttyMSM0,115200n8` (and UART was disabled in DTS), `/dev/console` returned `-ENODEV`. In Ubuntu's initramfs `/init`, line 318 executes:
  ```sh
  exec run-init "${rootmnt}" "${init}" "$@" <"${rootmnt}/dev/console" >"${rootmnt}/dev/console" 2>&1
  ```
  In POSIX `sh`, a redirection failure on the special builtin `exec` causes a non-interactive shell (PID 1!) to immediately `exit 1`.
- **Fix**: Add `console=tty0` **after** `console=ttyMSM0,115200n8` (the last `console=` binds `/dev/console`, and dummy VT `tty0` opens cleanly) plus `noresume` (avoids a 30s wait for nonexistent swap). Boot time to SSH dropped to ~21s immediately.

---

## 12. QCA6390 Zero Factory MAC (`00:00:00:00:00:00`) & `wpa_supplicant` Exhaustion
- **Symptom**: `ath11k_pci` probed `QCA6390 hw2.0` cleanly and created `wlp1s0`, but `NetworkManager` marked it `unavailable` (`wpa_supplicant: Could not set interface wlp1s0 flags (UP): Cannot assign requested address`, giving up after 5 retries).
- **Root Cause**: OPLUS QCA6390 modules rely on NV MAC (`use-nv-mac`) instead of OTP, so `ath11k_pci` initializes with MAC `00:00:00:00:00:00`, which Linux refuses to bring `UP`. An initial udev rule matching `ACTION=="add", DRIVERS=="ath11k_pci"` raced with `wlan0` -> `wlp1s0` renaming.
- **Fix**: Match `ACTION=="add|move", SUBSYSTEM=="net", KERNEL=="wl*"` in `/etc/udev/rules.d/99-bitra-wifi-mac.rules` to call `/usr/sbin/bitra-wifi-mac.sh %k`, which assigns a stable locally-administered MAC derived from `/etc/machine-id` (or `/var/lib/bitra/wlan_mac` if provided) whenever the interface reports `00:00:00:00:00:00`.

---

## 13. Qualcomm RPMh Regulators Show `state=unknown` & Leave OLED Powered On
- **Symptom**: Declaring the OLED LDOs (`vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15`) in DTS without `regulator-always-on` left them in `state=unknown`, and the OLED splash stayed lit.
- **Root Cause**: `qcom-rpmh-regulator` has no hardware enable readback, so `vreg->enabled` starts at `-EINVAL` (`state=unknown`). In `drivers/regulator/core.c`, `regulator_late_cleanup()` skips any regulator where `_regulator_is_enabled(rdev) <= 0`, so AOP never receives `RPMH_REGULATOR_REG_ENABLE = 0`.
- **Fix**: Add `regulator-boot-on;` (without `regulator-always-on;`) to `vreg_l13a_3p0`, `vreg_l14a_1p8`, and `vreg_l2c_1p15`. During probe, Linux marks them enabled; at `boot + ~31s` (`deferred_probe_timeout`), `regulator_late_cleanup()` sees `use_count == 0` and actively sends `ENABLE = 0` to AOP (`state=disabled`), physically powering off the OLED panel and dropping idle power to ~1.5 W.

---

## 14. MPS MP2650 2S Charger Control (`CHG_EN` Bypass vs `LEARN_EN` HIZ & 40s WDT)
- **Key Hardware Details Verified Against `oplus_mp2650.c` and Live I2C5 (`0x5c`)**:
  - `BQ28Z610` lives on **`&i2c16` (`i2c@888000`)** (not `i2c8`), and `MP2650` lives on **`&i2c5` (`i2c@994000`)**.
  - `REG09 bits 5:4` controls the hardware watchdog (default 40s resets charger registers); our mainline driver disables WDT on probe so 24/7 charge-limit settings stick.
  - `REG08 bit 4` (`CHG_EN = 0`) stops battery charging while **USB continues powering VSYS** (`inhibit-charge` bypass mode).
  - `REG08 bit 3` (`LEARN_EN = 1`) enters **HIZ / force-discharge** mode (USB input drops to ~50 mA so an overfull 100% battery discharges safely down to 75% without unplugging the cable).
  - `REG16..REG1F` provide live 10-bit ADCs (VBAT/VSYS/ICHG `12.5 mV|mA/LSB`, VIN `25 mV/LSB`, IIN `6.25 mA/LSB`).
