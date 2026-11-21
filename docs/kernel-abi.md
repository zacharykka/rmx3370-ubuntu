# Kernel ABI Ledger

| Release | Kernel Commit | Notes |
|---|---|---|
| `7.4.0-rc3-bitra1` | `5c10bc2c0` | First Ubuntu 24.04.5 LTS Server build (Stage-1 DTS + server/container/Wi-Fi/MHI modules); flashed & verified cold boot |
| `7.4.0-rc3-bitra2` | pre-commit | Step 6.1+6.2 RAM bring-up: QCA6390 Wi-Fi 6 (`pcie0` + `qca6390-pmu` + `ath11k_pci`), TI BQ28Z610 2S fuel gauge (`i2c16@0x55`), I2C5 enabled for MP2650 (`0x5c`) |
| `7.4.0-rc3-bitra3` | pre-commit | Step 6.3 RAM bring-up: Mainline MPS MP2650 2S charger driver (`mp2650_charger.c`, `charge_behaviour` bypass/HIZ anti-swelling control) |
| `7.4.0-rc3-bitra4` | `5f3199e3a` | Step 6.1–6.4 Server MVP: QCA6390 Wi-Fi 6 + BQ28Z610 + MP2650 2S charger + `regulator-boot-on` OLED power-off rails (`vreg_l13a_3p0`, `vreg_l14a_1p8`, `vreg_l2c_1p15`) |
