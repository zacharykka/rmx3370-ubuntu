# Technical Debt & Temporary Workarounds

| ID | Item | Current State | Proper Fix & Exit Criteria |
|---|---|---|---|
| TD-01 | PSCI CPU/cluster deep idle states disabled in `sm8250-realme-bitra.dts` | Deleted `cpus/idle-states`, `cpus/domain-idle-states`, and `power-domains = <&cluster_pd>` on `apps_rsc` and `cpu0..7` (matches stock `lpm_levels.sleep_disabled=1`) | Investigate RMX3370 PSCI OSI mode entry parameters (`psci: OSI mode supported, failed to set PC mode: -3`) once Ubuntu Server is installed; verify safe idle power savings without hang |
| TD-02 | Root DT `compatible` overwritten by stock `bitra_dtbo_0.dtbo` | Runtime `/proc/device-tree/compatible` becomes `qcom,kona-mtp qcom,kona qcom,mtp` because stock `dtbo` partition has a root overlay fragment | Acceptable for server bringup (`qcom,kona` works); long-term option is either ignoring harmless `cpufreq-dt` `-17` probe error or shipping a clean DTBO only if explicitly desired (avoid touching stock `dtbo` partition for now) |
| TD-03 | `rtc-pm8xxx` reads raw PMIC counter (1970-03-19) | No SDAM offset `nvmem-cells` wired yet | Wire PM8150 SDAM RTC offset in Step 6 + configure `chrony` + `fake-hwclock` on Ubuntu 24.04 |
| TD-04 | SM8250-AC 3.1872 GHz prime-core OPP | **Resolved** in `7.4.0-rc3-bitra5` (`cpu7_opp22`, 0 OPP errors in dmesg, verified 3.1872 GHz boost) | Closed |
| TD-05 | `adreno_smmu` (`3da0000.iommu`) deferred timeout warning (10s) | `gpucc` is built as module (`=m`) and not loaded in Stage-1 RAM initrd | Resolves automatically once Ubuntu rootfs loads modules or when GPU/MDSS is configured in Step 6 |
