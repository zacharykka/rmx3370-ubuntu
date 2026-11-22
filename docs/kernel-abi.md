# Kernel ABI Ledger

| Release | Kernel Commit | Notes |
|---|---|---|
| `7.4.0-rc3-bitra1` | `5c10bc2c0` | First Ubuntu 24.04.5 LTS Server build (Stage-1 DTS + server/container/Wi-Fi/MHI modules); flashed & verified cold boot |
| `7.4.0-rc3-bitra2` | pre-commit | Step 6.1+6.2 RAM bring-up: QCA6390 Wi-Fi 6 (`pcie0` + `qca6390-pmu` + `ath11k_pci`), TI BQ28Z610 2S fuel gauge (`i2c16@0x55`), I2C5 enabled for MP2650 (`0x5c`) |
| `7.4.0-rc3-bitra3` | pre-commit | Step 6.3 RAM bring-up: Mainline MPS MP2650 2S charger driver (`mp2650_charger.c`, `charge_behaviour` bypass/HIZ anti-swelling control) |
| `7.4.0-rc3-bitra4` | `5f3199e3a` | Step 6.1–6.4 Server MVP: QCA6390 Wi-Fi 6 + BQ28Z610 + MP2650 2S charger + `regulator-boot-on` OLED power-off rails (`vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15`) |
| `7.4.0-rc3-bitra5` | `af6f3598c` | Step 6.5: USB Type-C dual-role OTG (`pm8150b_typec` + `usb_1_dwc3` `dr_mode="otg"` + MP2650 5V OTG VBUS boost regulator) + SM8250-AC 3.1872 GHz prime-core OPP (`cpu7_opp22`) |
| `7.4.0-rc3-bitra6` | pre-commit | P1.5 probe: enable PCIe2 (`1c10000.pcie`, `pcie2_phy`) + SDX55M control pinctrl (`mdm2ap_default`, `ap2mdm_default`) |
| `7.4.0-rc3-bitra7` | pre-commit | P1.5 SDX55M Sahara bring-up: override 17cb:0306/010c to qcom-sdx55m on realme,bitra, add MHI SBL SAHARA ch 2/3, expose WWAN_PORT_SAHARA |
| `7.4.0-rc3-bitra8` | pre-commit | Docker full iptables-nft/nf_tables compat (`CONFIG_NFT_COMPAT`, `XT_NAT`, `XT_MASQUERADE`, `IP_NF_*`, `IP6_NF_*`) + SDX55M GICv3-MBI PCIe2 + dedicated MHI SAHARA event ring & `CONFIG_MHI_BUS_DEBUG` |
| `7.4.0-rc3-bitra9` | `833b48fde` | Docker full `iptables-nft`/`iptables-legacy` netfilter support + P1.5 built-in SDX55M 5G modem (PCIe2 GICv3-MBI, MHI SAHARA 2/3 + EFS 10/11 + IP_CTRL 18/19 + DUN 32/33, `WWAN_PORT_SAHARA` & `WWAN_PORT_EFS`, continuous Sahara EFS Sync + QRTR TFTP + ModemManager SMS) |
| `7.4.0-rc3-bitra10` | `1b62f9d0a` | SDX55M 5G cellular data readiness: resize MHI `IPCR` (ch 20/21) from 8 -> 64 descriptors on `SW_DATA` ER2 (256 entries) so all 35+ SDX55M QRTR QMI services (`WDS`/`WDA`/`NAS`/`UIM`/`WMS`) register reliably on cold boot without burst drops, while preserving upstream ER 3-6 and IPA `HW_DATA` ER 5/6 (`IP_HW0` ch 100/101) untouched |
