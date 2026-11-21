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

---

## 15. Docker `iptables v1.8.10 (nf_tables): RULE_APPEND failed (No such file or directory)`
- **Symptom**: `dockerd` failed on startup inside `Error initializing network controller` with `iptables v1.8.10 (nf_tables): RULE_APPEND failed (No such file or directory): rule in chain PREROUTING`.
- **Root Cause**: Ubuntu 24.04's default `iptables-nft` translates `iptables` rules into `nf_tables` expressions backed by xtables compat modules (`CONFIG_NFT_COMPAT`, `CONFIG_NETFILTER_XT_NAT`, `CONFIG_NETFILTER_XT_TARGET_MASQUERADE`, `CONFIG_IP_NF_NAT`, `CONFIG_BRIDGE_NETFILTER`), which were missing from the minimal `defconfig` + `nf_tables` fragment.
- **Fix**: Enable `CONFIG_NFT_COMPAT=m`, `CONFIG_NETFILTER_XT_NAT=m`, `CONFIG_NETFILTER_XT_TARGET_{MASQUERADE,REDIRECT}=m`, `CONFIG_NETFILTER_XT_MATCH_{STATE,MULTIPORT,LIMIT}=m`, `CONFIG_IP_NF_*`, `CONFIG_IP6_NF_*`, `CONFIG_NFT_{REDIR,REJECT*}`, and `CONFIG_BRIDGE_NETFILTER=m` in `kernel-cfg/10-bitra-server.config`.

---

## 16. NetworkManager `/etc/resolv.conf` Pointing to Uninstalled `systemd-resolved` (`127.0.0.53`)
- **Symptom**: After connecting Wi-Fi via `nmcli`, `apt update` could not resolve hostnames when a static `/etc/resolv.conf` was removed or symlinked to `/run/NetworkManager/resolv.conf`.
- **Root Cause**: Without `systemd-resolved` installed, NetworkManager must be explicitly configured with `dns=default` so it writes DHCP-provided DNS servers directly into `/etc/resolv.conf`.
- **Fix**: Ship `/etc/NetworkManager/conf.d/10-bitra-dns-default.conf` (`[main]
dns=default`) in `bitra-device-support`.

---

## 17. SDX55M PCIe2 SMMU Context Fault (`iova=0x64100000`, `SID=0x1d01`)
- **Symptom**: Enabling `&pcie2` let `mhi-pci-generic` load `sbl1.mbn` via BHI, but as soon as SBL initialized MHI, `arm-smmu 15000000.iommu` threw `Unhandled context fault: iova=0x64100000, SID=0x1d01` and MHI timed out.
- **Root Cause**: Upstream `pcie-designware-host` assigns `pp->msi_data = pp->cfg0_base` (`0x64100000`) for DWC iMSI-RX; SDX55M SBL's MHI MSIs escaped iMSI-RX into the SMMU. Stock RMX3370 routes PCIe2 MSIs through SM8250's native **GICv3-MBI** (`qcom,pcie2_msi@17a10040`, SPIs `0x340..0x35f`).
- **Fix**: Enable GICv3-MBI on `&intc` (`msi-controller; mbi-alias = <0x0 0x17a10000>; mbi-ranges = <864 32>;`) and map `&pcie2` with `msi-map = <0x0 &intc 0x0 0x1000>;` (leaving `&pcie0` Wi-Fi untouched on DWC iMSI-RX).

---

## 18. SDX55M PCI ID Collision (`17cb:0306` / `17cb:010c`) & ABL Root `compatible` Override
- **Symptom**: SDX55M in PBL/BHI reports PCI ID `17cb:0306` with subsystem `17cb:010c`, which `mhi_pci_generic.c` matched to `mhi_foxconn_sdx55_info` (a flash-equipped M.2 laptop card with `.fw = NULL`). Checking `of_machine_is_compatible("realme,bitra")` also missed because stock ABL DTBO overwrites the root node `compatible` to `qcom,kona-mtp`.
- **Fix**: Override `mhi_foxconn_sdx55_info` -> `mhi_qcom_sdx55_info` when `of_machine_is_compatible("qcom,sm8250") || of_machine_is_compatible("qcom,kona")`, with a dedicated RMX3370 MHI channel/event table (`SAHARA 2/3`, `DIAG 4/5`, `EFS 10/11`, `QMI 14/15`, `IP_CTRL 18/19`, `IPCR 20/21`, `DUN 32/33`, `IP_SW0`, `IP_HW0`, `.no_m3 = true`, `.sideband_wake = true`, `.timeout_ms = 60000`).

---

## 19. SDX55M Stalls in SBL After Sahara `DONE_RESP=1` Without `ap2mdm_status` (GPIO 56)
- **Symptom**: After loading all 15 Sahara images (`qdsp6sw.mbn`, `apps.mbn`, EFS, TZ/AOP/HYP) cleanly (`DONE_RESP image_tx_status=1`), SDX55M stayed in SBL indefinitely instead of entering AMSS. Also, Ubuntu 24.04's `gpiod 1.6.3` returned `EINVAL` because Linux 7.4 disables legacy `CONFIG_GPIO_CDEV_V1`.
- **Fix**: Drive SM8250 TLMM `ap2mdm_status` (GPIO 56) = `1` and `ap2mdm_errfatal` (GPIO 57) = `0` via Linux GPIO cdev ABI v2 ioctl (`bitra-sdx55-gpio.py` / `bitra-ap2mdm-gpio.service`). SDX55M immediately raises `mdm2ap_status` (GPIO 3) = `1` and enters `MISSION MODE (AMSS)` within 1 second.

---

## 20. Stock `tftp_server` QRTR Service `4096` Encoding (`tqftpserv-sdx55`)
- **Symptom**: Upstream `tqftpserv` failed to serve SDX55M MPSS (`MPSS` never sent TFTP requests) because upstream scans `/sys/class/remoteproc` (which does not exist for PCIe-attached SDX55M) and only registers QRTR `Service 4096` once.
- **Root Cause**: Reverse-engineering vendor `tftp_server` revealed it registers `Service 4096` raw instances `1..10` on **10 separate QRTR sockets** (`qrtr_publish(fd[i], 4096, /*version=*/1..10, /*instance=*/0)`). Calling `qrtr_publish()` repeatedly on the same fd overwrites previous registrations.
- **Fix**: Built `tools/tqftpserv-sdx55/` publishing `Service 4096` versions `1..10` on 10 separate sockets with 2 MiB buffers and direct `/lib/firmware/` + `/var/lib/tqftpserv/` mapping. MPSS immediately reads `/lib/firmware/modem_pr/...` (`711_0_0.mbn`, `mbn_sw.dig`) and writes `/readwrite/mcfg.tmp`.

---

## 21. SDX55M Periodic ~120–150s Crash (`remotefs_sahara.c:850` EFS Sync Timeout)
- **Symptom**: ~120–150s after entering AMSS, SDX55M asserted `mdm2ap_errfatal=1` and triggered a PCIe2 Link Down.
- **Root Cause**: Capturing the live Sahara `MEM_DEBUG` dump (`md_SHRDIMEM.BIN`) revealed the exact MPSS assertion:
  `ssr:AP:remotefs_sahara.c:850:Assertion remotefs_sahara_info.sahara_status == SAHARA_END_OF_IMG_TRANSFER fail:`
  SDX55M runs in Remote EFS mode (`sdx55.rmtefsmd.prod`) and periodically pushes 2 MiB `m9kefs1`/`m9kefs2` snapshots over **MHI channels `10/11` (`"EFS"`)** using Sahara `MEM_DEBUG` (`mode=2`). Without a host EFS Sync responder on channels `10/11`, `remotefs_sahara` timed out and crashed the modem.
- **Fix**: Expose MHI channels `10/11` (`"EFS"`) via `WWAN_PORT_EFS` (`/dev/wwan0efs0`) and run `bitra-sdx55-efs-sync.service`, which receives `m9kefs1`/`m9kefs2` (~330 ms each), writes them atomically to `/var/lib/bitra/sdx55m-efs-rw/` (**never touching raw UFS EFS partitions**), and completes the transaction with `SAHARA_RESET (0x07)` / `SAHARA_RESET_RESP (0x08)`.

---

## 22. QCA6390 Wi-Fi Power Save Latency Spikes (`300–1200 ms`) & SSH Banner Timeouts
- **Symptom**: Over Wi-Fi 6 (`wlp1s0`), `ping` periodically spiked to `380–1200 ms` and SSH connections occasionally timed out during banner exchange.
- **Root Cause**: Ubuntu ships `/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf` (`wifi.powersave = 3`), keeping `ath11k_pci` (`QCA6390`) in 802.11 power-save sleep between DTIM beacons.
- **Fix**: Ship `/etc/NetworkManager/conf.d/99-bitra-wifi-powersave-off.conf` (`[connection]
wifi.powersave = 2`) in `bitra-device-support` (latency drops to ~6 ms consistently).
