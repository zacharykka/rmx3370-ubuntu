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

---

## 23. SDX55M 5G Cellular Data (`qrtr://3` QMI + `rmnet_data0` + Dual-SIM DSDS)
- **Root Findings**:
  1. On RMX3370 SDX55M, cellular QMI services (`WDS=1`, `DMS=2`, `NAS=3`, `WMS=5`, `UIM=11`, `WDA=26`) live on **`QRTR Node 3`** (`IPCR` ch 20/21), **not** `/dev/wwan0qmi0` (`QMI0` ch 14/15).
  2. During initial boot, MPSS publishes its 35+ QMI services *after* `tqftpserv-sdx55` serves MCFG; rebinding **only** `mhi0_IPCR` (`qcom_mhi_qrtr` driver unbind/bind — **never** `rmmod qrtr_mhi`, which Wi-Fi `mhi1_IPCR` also shares!) replays all 35+ QMI services cleanly. We also resized `IPCR` from 8 -> 64 descriptors on dedicated `SW_DATA` ER2 (matching stock DTS) in `bitra10`.
  3. On `qrtr://3`, each process gets its own QRTR client port, so `qmicli --client-cid=...` cannot span multiple CLI calls (and `qmi-proxy` does not proxy `qrtr://`). Our zero-dependency Python client `/usr/sbin/bitra-wwan` uses a single persistent `AF_QIPCRTR` (`42`) socket to execute `WDA Set Data Format` (`raw-ip + QMAP` on PCIe EP `3/4`), `WDS Bind Mux Data Port (0x00A2, mux_id=1)`, `WDS Bind Subscription (0x00AF, slot 1/2)`, `WDS Set IP Family (0x004D)`, `WDS Start Network (0x0020)`, and `WDS Get Current Settings (0x002D)` onto `rmnet_data0@mhi_hwip0`.
  4. When swapping a new physical SIM card into SDX55M, MPSS leaves its USIM app in `detected` state until `UIM Change Provisioning Session` activates `primary-gw-provisioning` / `secondary-gw-provisioning`; `bitra-wwan` automates this check before dialing.

---

## 24. USB CDC-ECM (`usb0`) Drops Right After Boot on `pm8150b_typec` (`tcpm`) Init
- **Symptom**: `bitra-usb-gadget.service` binds `a600000.usb` at `t~10.6s`, host gets DHCP, then `usb0` drops to `NO-CARRIER` (`udc/state = not attached`) and even rebinding `g1/UDC` alone does not restore it.
- **Root cause**: `pm8150b_typec` (`tcpm`) probes ~100 ms later (`t~10.76s`), performs an initial ~1.2 s `PORT_RESET`, and invokes `usb-role 0 (NONE)`, detaching `dwc3` while `g1/UDC` still appears bound.
- **Fix**: `bitra-usb-gadget.sh` (`bitra-device-support >= 0.9`) runs a 6 s post-boot check: if `udc/state != configured` and `usb_role != host` (preserving OTG host mode), it cycles `/sys/class/usb_role/a600000.usb-role-switch/role` (`none -> device`) and rebinds `g1/UDC`.

---

## 25. QCA6390 Wi-Fi 6 Power Save Override Order (`99-*` vs `default-*`)
- **Symptom**: `/etc/NetworkManager/conf.d/99-bitra-wifi-powersave-off.conf` did not take effect (`iw dev wlp1s0 get power_save` stayed `on`, causing 300–1200 ms latency spikes).
- **Root cause**: Ubuntu ships `/etc/NetworkManager/conf.d/default-wifi-powersave-on.conf` (`wifi.powersave = 3`), and lexicographically `"d"` (ASCII 100) sorts *after* `"9"` (ASCII 57), overriding `99-*`.
- **Fix**: Renamed to `zz-bitra-wifi-powersave-off.conf` (`"z" > "d"`) in `bitra-device-support >= 0.9`, with `postinst` cleaning up the old `99-*` file. Confirmed `Power save: off` (~4–8 ms ping).

---

## 26. Carrier Idle PS Detach / `ModemManager` AT-Init Interrupting 5G NR SA
- **Symptom**: `ModemManager` initializing `/dev/wwan0at0` on boot (or carrier 3-minute idle timeout `network forced PS detach`) can leave SDX55M NAS in `limited` / `power-save` while a bound WDS socket still looks active.
- **Fix**: `bitra-wwan` (`bitra-device-support >= 0.9`) starts `After=ModemManager.service`, runs `ensure_nas_registered()` (cycling `DMS low-power -> online` if NAS is stuck in `limited`/`power-save`), and monitors both WDS (`0x0022`) and NAS Serving System (`0x0024`) every 15 s to auto-reconnect on carrier detach.

---

## 27. Stock `dtbo.img` Root `compatible` Override Breaks `msm-mdss` UBWC & Missing `&gmu` Hard-Resets on Probe
- **Symptoms**:
  1. `msm-mdss ae00000.display-subsystem` failed probe with `-22` (`Couldn't find UBWC config data for this platform!`).
  2. After fixing UBWC, loading `msm.ko` with `&gpu { status = "okay"; }` but without `&gmu { status = "okay"; }` triggered an instant SoC reset.
- **Root Cause**:
  1. Stock ABL `dtbo.img` rewrites the root `/` `compatible` property at boot to `"qcom,kona-mtp", "qcom,kona", "qcom,mtp"`, stripping `"qcom,sm8250"` that upstream `drivers/soc/qcom/ubwc_config.c` matches on.
  2. Adreno 650 on SM8250 requires `&gmu` enabled alongside `&gpu`.
- **Fix**: Add `{ .compatible = "qcom,kona", .data = &ubwc_4_0_hbb16 }` in `drivers/soc/qcom/ubwc_config.c` and enable both `&gmu` and `&gpu` in `sm8250-realme-bitra.dts`.

---

## 28. Adreno 650 Split Firmware Requirement (Stock `a650_zap.mbn` + Upstream `a650_sqe.fw` >= v95)
- **Symptom**: Using stock Android RUI 3.0 `a650_sqe.fw` failed GPU init with `a650 SQE ucode is too old. Have version 93 need at least 95`; conversely, generic upstream `a650_zap.mbn` fails TrustZone signature validation on RMX3370.
- **Fix**: Pair the device-signed stock **`vendor/firmware/a650_zap.elf`** (installed as `/lib/firmware/qcom/sm8250/realme/bitra/a650_zap.mbn`) with upstream `linux-firmware` **`a650_sqe.fw` (v112)** and **`a650_gmu.bin`**.

---

## 29. Synaptics `S3908` Native 8x Subpixel Coordinates (`8639x19199`) & I2C Probe Race
- **Symptoms**:
  1. First probe timed out (`CMD_IDENTIFY failed: -110`) because the threaded IRQ handler read the boot `REPORT_IDENTIFY` packet concurrently with `probe()`'s I2C transfer.
  2. Setting `touchscreen-size-x = <1080>` / `touchscreen-size-y = <2400>` clipped touch input to the top-left 1/8th of the screen.
- **Fix**: Serialize all I2C transfers in `drivers/input/touchscreen/synaptics_tcm_i2c.c` with `rw_lock` (and drain the initial boot identify after reset), and expose the controller's native `8639x19199` range directly so `libinput` scales cleanly to `1080x2400`.

---

## 30. Volume Down Key Hardware Wiring (`pm8150` GPIO 7, Not PMIC PON `resin`)
- **Symptom**: Power (`pm8941_pwrkey`) and Volume Up (`pm8150` GPIO 6) worked, while Volume Down reported zero events when wired to `&pon_resin`.
- **Root Cause**: On RMX3370 (confirmed in stock `live.dts`), both volume buttons are discrete PMIC GPIOs on `pm8150`: Volume Up = GPIO 6 (`spmi-gpio 5`), Volume Down = GPIO 7 (`spmi-gpio 6`), both `GPIO_ACTIVE_LOW`.
- **Fix**: Move `key-vol-down` (`KEY_VOLUMEDOWN`) into `gpio-keys` on `&pm8150_gpios 7 GPIO_ACTIVE_LOW` with `vol_down_pin` pinctrl (`gpio7`, pull-up).

---

## 31. GTK4 Apps (`kgx`, `nautilus`, `gnome-control-center`) Hang 25–90s on Launch in Phosh (`xdg-desktop-portal-gnome`)
- **Symptom**: Launching GTK4 apps in Phosh caused a 25+ second black screen (`Console`, `Settings`) or appeared to crash and then open 25s later (`Files` hitting Phosh's 5s startup timeout).
- **Root Cause**: Ubuntu's `nautilus` / `gnome-control-center` pull in `xdg-desktop-portal-gnome`, whose user unit declares `Requisite=graphical-session.target` (which Phosh's non-systemd `gnome-session` does not start). Because `phosh-portals.conf` leaves several interfaces (`Background`, `Wallpaper`, `ScreenCast`, `Screenshot`) unmatched, `xdg-desktop-portal` fell back to `gnome.portal`, failing immediately on systemd dependency while hanging 25s per interface on D-Bus (90s+ total).
- **Fix**: Remove `xdg-desktop-portal-gnome` and ship `/etc/xdg/xdg-desktop-portal/phosh-portals.conf` in `bitra-device-support 1.0` explicitly setting `default=gtk` and `none;` for unsupported GNOME Shell portal interfaces. `xdg-desktop-portal.service` startup drops from `90s (timeout)` to `0.08s`, and all GTK4 apps open instantaneously.

---

## 32. Cold-Boot Race: Built-In `arm-smmu 3da0000.iommu` vs Module `gpucc_sm8250` (`deferred probe timeout`)
- **Symptom**: On roughly half of cold boots, `arm-smmu 3da0000.iommu` (`&adreno_smmu`) timed out at `t ~ 10.74s` with `deferred probe timeout, ignoring dependency` (`probe failed with error -110`), causing `adreno 3d00000.gpu` to fail with `-19` (`-ENODEV`) and leaving `/dev/dri/card0` unavailable.
- **Root Cause**: `CONFIG_ARM_SMMU=y` is built-in, and `&adreno_smmu` (`3da0000.iommu`) depends on `&gpucc` (`GPU_CC_AHB_CLK`, `GPU_CX_GDSC`), which was compiled as a loadable module (`CONFIG_SM_GPUCC_8250=m`). When `systemd-udevd` loaded `gpucc_sm8250.ko` right around Linux's 10-second default `deferred_probe_timeout`, it intermittently lost the race.
- **Fix**: Set `CONFIG_SM_GPUCC_8250=y` and `CONFIG_SM_DISPCC_8250=y` in `kernel-cfg/10-bitra-server.config` so both GPU and display clock controllers are built-in alongside `gcc-sm8250` and `arm-smmu`. `3da0000.iommu` now probes deterministically during early boot (`t < 1s`) with zero deferred-probe timeouts.

---

## 33. QCA6390 Bluetooth UART `Invalid line -19` & Unconfigured Controller (`00:00:00:00:5A:AD`)
- **Symptoms**:
  1. Enabling `&uart6` without an alias logged `qcom_geni_serial 998000.serial: Invalid line -19` and blocked `sync_state()`.
  2. After fixing the alias and downloading `qca/htbtfw20.tlv` + `qca/htnv20.bin`, `hci0` stayed in `DOWN RAW` (`00:00:00:00:5A:AD`) and `btmgmt` hung when run from a systemd service (where stdin is `/dev/null`).
- **Fix**:
  1. Add `serial1 = &uart6;` under `aliases` in `sm8250-realme-bitra.dts`.
  2. Ship `bitra-bt-addr.service` (`bitra-device-support >= 1.1`) running `Before=bluetooth.service`, polling until `hci0` firmware download completes and invoking `true | timeout 3 btmgmt --index 0 public-addr "$BTMAC"` (piping stdin avoids BlueZ `btmgmt`'s `epoll_ctl` `EPERM` on `/dev/null`).

---

## 34. Dual NXP `TFA9874` Stereo Speakers: `TDMLUTER` (`TDMNBCK=0`) & `TERTIARY_MI2S_RX` on `SD1` (`gpio137`)
- **Symptoms**:
  1. With `TDMNBCK=1`, `tfa9874` reported `CLKS not locked (st0=0x0056 st1=0x0100)` (`TDMERR=1, TDMLUTER=1`).
  2. After fixing `TDMNBCK=0` (32 BCLKs/frame for 16-bit stereo), both amps locked (`st1=0xe2c2`, `PLLS=CLKS=AMPS=SWS=DCDCA=1`) yet produced silence.
- **Root Cause**:
  1. On `TFA9874`, `TDMNBCK = 0` selects 32 BCLKs/frame (16-bit stereo I2S), `1` = 48 BCLKs, `2` = 64 BCLKs.
  2. In stock RMX3370 `live.dts`, `qcom,msm-dai-q6-mi2s-tert` uses `qcom,msm-mi2s-rx-lines = <0x02>` (**SD line 1 = `gpio137` `mi2s2_data1`**) for speaker RX and `tx-lines = <0x01>` (`gpio134` `mi2s2_data0`) for VI feedback. Upstream `sm8250.dtsi`'s `tert_mi2s_active` only muxes `gpio133/134/135`.
- **Fix**: Set `TDMNBCK=0` for 16-bit I2S in `sound/soc/codecs/tfa9874.c`, add `tert_mi2s_data1_active` (`gpio137`, `mi2s2_data1`), and set `qcom,sd-lines = <1>` on `&q6afedai` `dai@20` (`TERTIARY_MI2S_RX`). Verified via dual-channel 880 Hz / 1320 Hz acoustic loopback (+50 dB SNR on both speakers and both `WCD9380` analog mics).

---

## 35. `systemd-backlight@backlight:ae94000.dsi.0.service` Fails After Headless OLED Blank
- **Symptom**: On headless boot, `systemd-backlight` attempted to restore saved brightness `0` clamped up to `102` after `bitra-oled-blank.service` powered off the panel, failing with `EINVAL` and marking systemd `degraded`.
- **Fix**: Mask `systemd-backlight@backlight:ae94000.dsi.0.service` in `bitra-device-support >= 1.1` so headless boot stays at `0 failed units` and OLED stays strictly off until `bitra-desktop start`.

---

## 36. Stereo Audio Quiet (-48 dB) & Channel Crosstalk (`q6asm-dai` `S24_LE` + `TFA9874` `TDMFSPOL`/`TDMDCE`)
- **Symptoms**:
  1. Even at 100% PipeWire volume, speaker output was whisper-quiet and the TFA9874 boost converter stayed at battery voltage (`reg 0x17 = 0x0144`, ~3.8 V).
  2. In GNOME Settings → Sound → Test, the Left/Right buttons were silent until `libcanberra-pulse` was installed; once working, Left played on both earpiece and bottom speaker while Right played only on the earpiece.
- **Root Causes**:
  1. `q6asm-dai` (`MultiMedia1`) advertises `S16_LE | S24_LE`. PipeWire picked `S24_LE`, which suffered an exact **8-bit (-48 dB) right-shift** when routed into the 16-bit `TERTIARY_MI2S_RX` backend on SM8250.
  2. Standard I2S starts Left (slot 0) on the **falling** edge of WS (`WS=0`), which requires **`TDMFSPOL = 1`** on TFA9874 (`TDMFSPOL = 0` inverted Left/Right slots).
  3. Enabling **`TDMDCE`** (`reg 0x23 bit 1`) routed the secondary TDM slot (`TDMDCS` = opposite stereo channel) into the amp, bleeding the opposite channel into `0x34`.
- **Fix**:
  1. Ship `/etc/wireplumber/main.lua.d/51-bitra-alsa-s16.lua` in `bitra-device-support >= 1.1` forcing `["audio.format"] = "S16LE"` on `alsa_output.platform-sound.*` / `alsa_input.platform-sound.*` — instantly restores +48 dB loudness and wakes up the 9V boost converter (`reg 0x17 = 0x0288`), allowing safe stock-conservative amp gains (`SpkrLeft=8` / `SpkrRight=9`, `TDMSPKG=7/6`).
  2. Fix `tfa9874.c` to set `TDMFSPOL = 1` for I2S `NB_NF`, disable `TDMDCE` (`reg 0x23 = 0x0001`), and apply stock RMX3370 `reg 0x68[6:0] = 0x4b`. Verified ~19 dB acoustic Left/Right isolation (`0x34` = top earpiece Left only, `0x35` = bottom speaker Right only).
  3. Install `libcanberra-pulse` alongside `sound-theme-freedesktop` for GNOME Settings test sounds.

---

## 37. USB CDC-ECM (`192.168.2.15`) Drops to `state=default` After Idle/Host Sleep
- **Symptom**: Because `mp2650` manages VBUS instead of `pm8150b`, `pm8150b_typec` stays in `TOGGLING` and `dwc3` (`a600000.usb`) can drop to `state=default` after host sleep or cable settle. Cycling `soft_connect` with a `0.3 s` pause re-enumerated too quickly for macOS DHCP (leaving the host stuck on `169.254.x.x`).
- **Fix**: Ship and enable `bitra-usb-watch.service` in `bitra-device-support >= 1.1` polling every 4 s when `mp2650-charger/online == 1` and `role != host`; when `state != configured`, it cycles `soft_connect` (`disconnect`, `sleep 1`, `connect`) so macOS cleanly re-triggers DHCP and recovers `192.168.2.15` automatically.

---

## 38. USB CDC-ECM (`192.168.2.15`) TX Queue Deadlock & macOS `169.254.x.x` APIPA Fallback
- **Symptom**: While connected to an awake macOS host, `usb0` periodically dropped and macOS fell back to link-local `169.254.x.x`. Live capture showed `usb0` **receiving** every macOS `DHCPDISCOVER` and `dnsmasq` emitting `DHCPOFFER`, while `en17` received `0` packets, `dwc3` `ep1in` had `0` queued TRBs, and `tc -s qdisc show dev usb0` showed an ever-growing TX `backlog` (65+ packets, `requeues > 0`).
- **Root Causes**:
  1. In `drivers/usb/gadget/function/u_ether.c`, `gether_connect()` never cleared `link->is_suspend`, so a USB suspend occurring before `ecm_set_alt(1)` (or an `ecm_disable()` while `in_ep` was not yet enabled) left `is_suspend = true` permanently. Every subsequent TX packet hit `netif_stop_queue()` + `ether_wakeup_host()` (which failed with `-EINVAL` because the link was already in `U0`), deadlocking TX forever.
  2. `gether_resume()` called `netif_start_queue()` *before* clearing `is_suspend = false` and did not call `netif_wake_queue()` to schedule the qdisc to drain the backlog.
  3. The gadget config advertised `bmAttributes = 0x80` (no remote wakeup), `&usb_1_dwc3` lacked `snps,usb2-gadget-lpm-disable`, and `bitra-usb-watch` cycled `soft_connect` on a single transient `state=default` sample.
- **Fix**:
  1. Patch `drivers/usb/gadget/function/u_ether.c`: clear `link->is_suspend = false` in `gether_connect()`, clear `is_suspend` *before* calling `netif_wake_queue()` in `gether_resume()`, and auto-resume in `rx_complete()` on `status == 0` whenever RX traffic arrives from an awake host.
  2. Add `snps,dis_u2_susphy_quirk;`, `snps,dis_enblslpm_quirk;`, and `snps,usb2-gadget-lpm-disable;` to `&usb_1_dwc3`.
  3. In `bitra-device-support >= 1.2`: set `bmAttributes = 0xe0`, run `dnsmasq --bind-dynamic --dhcp-authoritative`, and require 2 consecutive non-`configured`/non-`suspended` polls before `bitra-usb-watch` cycles `soft_connect`.

---

## 39. SLPI Sensors: OPLUS `SMEM_SENSOR` (Item 130) Requirement & `hexagonrpcd` `socinfo/` Write-Loop Trap
- **Symptoms**:
  1. With `&slpi` and `hexagonrpcd` enabled alone, only accelerometer/gyroscope (`icm4x6xa`) probed (with inverted Z-axis), while magnetometer, ambient light (`stk3329`), and proximity returned `UNKNOWN`.
  2. Creating `/usr/share/qcom/sm8250/realme/bitra/socinfo/` caused SLPI to match `/vendor/etc/sensors/config/*.json` and loop forever attempting to write `/mnt/vendor/persist/sensors/registry/registry/../temp.json` (rejected by read-only `hexagonrpcd`), stalling the `registry` sensor for >30 s.
  3. Upstream `80-iio-sensor-proxy.rules` only matched `ssc-light` and `ssc-compass`, causing `iio-sensor-proxy` to exit with `No sensors`.
- **Fix**:
  1. Add built-in deferrable platform driver `drivers/soc/qcom/oplus_bitra_sensor_smem.c` (`CONFIG_QCOM_OPLUS_BITRA_SENSOR_SMEM=y`), matching `oplus,dtsi_no == 0x5473` (because ABL DTBO overwrites `/compatible`), which populates Qualcomm SMEM item `130` (`4768` bytes = `struct oplus_sensor_info`) at `t ~ 0.4 s` before SLPI boots at `t ~ 3.2 s`. All 6 sensors (Accel, Gyro, Mag, Compass, Light, Proximity) now probe with proper orientation.
  2. Omit `socinfo/` so SLPI uses the pre-parsed read-only snapshot from `/var/lib/bitra/persist-sensors/registry/registry/`.
  3. Ship `/etc/udev/rules.d/81-bitra-ssc-sensors.rules` (enabling `ssc-accel ssc-light ssc-proximity ssc-compass` + `FEEDBACKD_TYPE="vibra"` for `aw8697-haptics`) and an `iio-sensor-proxy` systemd drop-in waiting for `hexagonrpcd-sdsp.service`.

---

## 40. Samsung `AMS662ZS01` OLED Boot Bright-White Flash, 31-Second White Screen & Known ~0.1 s Handover Flash
- **Symptoms**:
  1. During boot/reboot, the OLED flashed blinding bright white for several seconds; after disabling `fb0`, the screen stayed solid bright white for **31.7 seconds** before snapping black.
  2. Stopping Phosh without `/dev/fb0` left all 4 OLED regulators enabled because `bitra-desktop` only toggled `/sys/class/graphics/fb0/blank`.
- **Root Causes**:
  1. In Linux, `regulator_late_cleanup()` runs **30 seconds** after `late_initcall_sync` (`t = 31.7 s`). Meanwhile, `clk: Disabling unused clocks` turned off display clocks at `t = 0.64 s` while all 4 OLED rails (`vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15`, and `gpio125` `vout`/ELVDD-ELVSS) remained powered on from ABL — driving the unclocked OLED panel solid white for 31 seconds.
  2. Earlier `panel-samsung-ams662zs01.c` also sent `brightness = 0x0200` + `DISPON` (`0x29`) in `.prepare()` before any frame was written to panel GRAM, causing a white/snow flash when waking the panel.
- **Fix & Remaining Known Limitation (`TD-06`)**:
  1. Model `gpio125` as built-in `regulator-fixed` (`vreg_panel_vout`, **without** `regulator-boot-on`), so `fixed.c` pulls `gpio125` LOW at `t = 0.25 s` *before* display clocks are disabled at `t = 0.64 s`, eliminating the 31-second white screen completely.
  2. Ship `/etc/modprobe.d/bitra-msm.conf` (`options msm fbdev=0` + `options drm_kms_helper fbdev_emulation=0`) so headless boot never creates `/dev/fb0` or wakes the OLED; Wayland/Phosh uses `/dev/dri/card0` directly, and `bitra-desktop stop`/`blank` disables all DRM CRTCs via `DRM_IOCTL_MODE_SETCRTC` so all 4 OLED rails immediately return to `disabled`.
  3. Match stock OPLUS `DSI_CMD_POST_ON_BACKLIGHT` in `panel-samsung-ams662zs01.c`: keep `DISPOFF` across `.prepare()`/`.enable()` with default brightness `0`, and only send `DISPON` (`0x29`) after a 20 ms frame delay on the first non-zero backlight update.
  4. **Known limitation (`TD-06`)**: Because ABL leaves the OLED powered on when handing off to Linux and `msm.ko` is a loadable module (not built-in with Qualcomm continuous-splash handover), cutting `vreg_panel_vout` directly at `t = 0.25 s` without a preceding DSI `DISPOFF`/`SLPIN` still produces a **very brief (~0.1 s) white capacitor-discharge flash** right after leaving the Bootloader/Fastboot screen. Eliminating that final ~0.1 s flash would require upstream `msm` SM8250 continuous-splash support.

---

## 41. USB Type-C Video Output (DisplayPort Alt-Mode) Is Physically Unsupported on RMX3370
- **Finding**: Verified via official hardware specifications and live `a600000.usb` link capability (`high-speed` USB 2.0 only) that the realme GT Neo 2 (`RMX3370`) Type-C receptacle only routes USB 2.0 D+/D- and CC lines (with `fsa4480@42` handling analog audio switching); SuperSpeed TX/RX lanes are not wired to the port. Native DisplayPort Alt-Mode over USB-C is physically impossible on both stock Android and mainline Linux. Use VNC/RDP/WayVNC (over Wi-Fi 6 or USB ECM) or a USB 2.0 DisplayLink adapter for external display output.

---

## 42. Qualcomm Venus Video Codec on Linux 7.4 SM8250: `qcom-iris` Crash, Split `venus.mdt` Squash, & `1.0.96` H.264 EOS Bug
- **Symptoms**:
  1. Enabling `&venus` on Linux 7.4 `defconfig` bound the new experimental `qcom-iris` driver (`CONFIG_VIDEO_QCOM_IRIS=m`), which failed loading split `venus.b19` (`-40`) and, even after squashing `venus.mbn`, crashed with `sys error (type: 1, session id:ff, data1:1, data2:deadbead)`. Meanwhile `qcom-venus` compiled out SM8250 (`#if !IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS)` in `venus/core.c`).
  2. After switching to classic `qcom-venus` (`# CONFIG_VIDEO_QCOM_IRIS is not set`), hardware encoding immediately worked (~300 fps), but decoding failed with `session error: event id:1007` (`HFI_ERR_SESSION_UNSUPPORTED_PROPERTY`) and H.264 decoding crashed the VPU firmware at EOS (`SFR message from FW: Exception: TID = Unknown IP = 0x3bcd4 FA = 0x0 cause = 0x6`).
- **Root Causes**:
  1. TrustZone PAS authentication on SM8250 expects a single squashed ELF (`venus.mbn`, 12 segments, 1.9 MiB) rather than split `venus.mdt` + `venus.b*`.
  2. RMX3370 stock firmware (`VIDEO.VPU.1.0-00096-PROD-2`) does not implement ChromeOS `HFI_PROPERTY_PARAM_VDEC_ENABLE_SUFFICIENT_SEQCHANGE_EVENT` (returning `0x1007`), which mainline `hfi_msgs.c` treated as fatal.
  3. Mainline `venus/vdec.c` only sent a NULL (`0`) EOS buffer address on IRIS2 for firmware `<= 1.0.87`, falling back to fake address `0xdeadb000` on `1.0.96`. Turning on Venus firmware debug logs (`VDBGFW`) revealed `ETB cmd state 2 addr deadb000 fLen 0 nFlags 1` immediately before the crash: on `1.0.96`, **H.264 decode requires `device_addr = 0` on EOS**, whereas **VP8 (`vpx_decoder.c:5646`) and HEVC require `0xdeadb000`**.
- **Fix**:
  1. Squash stock `venus.mdt` + `venus.b*` into `/lib/firmware/qcom/sm8250/realme/bitra/venus.mbn` and disable `CONFIG_VIDEO_QCOM_IRIS` so classic `qcom-venus` binds SM8250.
  2. Patch `qcom-venus` (3 lines in `0009`): treat `HFI_ERR_SESSION_UNSUPPORTED_PROPERTY` as non-fatal in `hfi_msgs.c`, restrict `HFI_PROPERTY_PARAM_VDEC_ENABLE_SUFFICIENT_SEQCHANGE_EVENT` to VP9 in `vdec.c`, and send `fdata.device_addr = 0` for `V4L2_PIX_FMT_H264` on `IS_IRIS2` while keeping `0xdeadb000` for HEVC/VP8/VP9. All 6 HW codecs (1080p H.264/HEVC & 720p VP9/VP8 decode, 1080p H.264/HEVC encode) now run consecutively at `7.3x–22.5x` realtime with zero `dmesg` errors.

---

## 43. PM8150 Read-Only `rtc0` & Systemd Build-Epoch Guard in Offline RTC Restore
- **Symptom**: Stock RMX3370 `live.dts` only exposes one PM8150 `sdam@b100` (no dedicated `rtc_offset` cell), so `rtc-pm8xxx` always reports raw monotonic seconds from 1970 (`1970-03-xx`). An initial `bitra-rtc-sync` script skipped restoring the saved offset whenever `date +%s >= 2024-01-01`.
- **Root Cause**: Ubuntu 24.04 `systemd` initializes system wall clock from its own build timestamp (`>= 2024`) before `sysinit.target` starts, tripping any `< 2024` guard and leaving the clock stale until `chronyd` eventually stepped it by 12+ seconds.
- **Fix**: In `bitra-device-support >= 1.3`, `bitra-rtc-sync restore` unconditionally applies `rtc0_since_epoch + saved_offset` whenever the computed target is `>= 2024-01-01` (`Before=time-sync.target chrony.service`), restoring offline wall-clock time to `<1 s` accuracy before networking starts.
