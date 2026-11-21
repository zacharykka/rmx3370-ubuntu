# AGENTS.md — rmx3370-ubuntu (realme GT Neo 2 主线 Linux + Ubuntu 移动服务器)

所有在本项目工作的执行者（AI agent 与人类维护者）必须遵守本文件。本文件只记录目标、已确认决策、授权边界、设备安全与提交规则，不记流水账或进度（进度见 `docs/status.md`）。

## 1. 设备与目标

- **目标设备**：realme GT Neo 2（商业型号 `RMX3370`，代号 `bitra`，OPLUS 项目号 `21619` / `0x5473`）。
- **核心硬件**：Qualcomm SM8250-AC（Snapdragon 870, `kona v2.1`, `msm-id = <0x164 0x20001>`）、12 GiB RAM、UFS 3.1（`sda11` `userdata` ≈ 226.5 GiB，**A-only 分区结构**）、QCA6390 Wi-Fi 6/BT、外挂 SDX55M 5G 基带（PCIe2+MHI）、TI BQ28Z610 双电芯电量计（I2C16 `0x55`）、MPS MP2650 2S 升降压充电芯片（I2C5 `0x5c`）、Samsung AMS662ZS01 AMOLED 面板（1080x2400 CMD+DSC）、Synaptics S3908 触控（I2C7 `0x4b`）。
- **产品定位**：高性能、自带 UPS 的 **24/7 ARM64 移动服务器**（无头为主，原生 Docker/Podman/cgroup v2/WireGuard/AppArmor/apt）。

## 2. 用户已确认的决策（2026-11-21）

1. **核心范围（选项 A + 短信评估跟进）**：
   - **MVP 必选**：SoC 基础与温控调频、UFS 3.1、USB 设备模式调试网络（CDC-NCM）、Wi-Fi 6（QCA6390 `ath11k_pci`）、TI BQ28Z610 电量计、MPS MP2650 2S 稳定充电 + **防鼓包限充/停充控制**、Samsung AMS662ZS01 原生 DRM **真熄屏断电（防 OLED 烧屏）**、USB Host/OTG。
   - **可选独立里程碑（基础服务器稳定后）**：评估并尝试打通内置 SDX55M 收发短信（MHI + `tqftpserv` + `ModemManager`，不动语音音频），同时保留 USB 4G 网卡作为低成本备选。
   - **不做**：桌面环境、相机、屏下指纹、震动马达、音频、传感器。
2. **数据处置**：允许清空当前 `sda11` (`userdata`) 上的 Ubuntu Touch 数据。
3. **系统架构**：**单系统主线 Ubuntu**（不保留 Android 双系统；官方 RUI 3.0 镜像留存在 Mac `<host-stock-backup-dir>/` 作恢复源）。
4. **分区方案（选项 A）**：不改 GPT 分区表，直接将整块 `sda11`（~226.5 GiB）格式化为 ext4 作 Ubuntu 根分区 `/`。
5. **发行版（选项 A）**：**Ubuntu 24.04 LTS Server (ARM64)**。
6. **调试与远程访问（选项 A）**：默认开启 USB 网段受限 SSH + Wi-Fi SSH，仅允许密钥登录，禁用密码登录。
7. **公开仓库**：公开到 GitHub `https://github.com/zacharykka/rmx3370-ubuntu`（编译机工作目录 `/root/rmx3370-ubuntu`）。
8. **固件与敏感数据边界**：
   - 原厂固件二进制（Wi-Fi/DSP/GPU/modem）、本机唯一数据（MAC、蓝牙地址、校准、EFS `mdm1m9kefs*`、序列号）、原始日志与备份**严禁提交进公开仓**，全部放 `private/`（已加入 `.gitignore`），公开仓只放提取脚本与清单。

## 3. 授权边界与真机拓扑（2026-11-21）

- **连接拓扑**：编译机位于 `<build-server>`；真机通过 USB 连接在用户本机 Mac 上。
- **需要每次明确批准的操作**：
  - `fastboot flash boot` 或向手机持久化写入任何分区；
  - 修改 GPT 分区表（当前方案不改 GPT）；
  - `git push` 推送到 GitHub、发版或改写已发布历史。
- **已授权自主执行的操作**：
  - 编译机上的源码拉取、内核与根文件系统编译、离线 DTBO 叠加测试、本地脚本与文档编写、`fastboot boot` 内存启动实验（必须带超时自动回退且只读挂载块设备）、只读取证。

## 4. 设备安全与工程铁律

- **一台设备同一时刻只有一个操作者**；离开当前系统前先确认电量（≥ 40%）。
- **每一步都必须可退回**：只读 → `fastboot boot` 内存启动（块设备只读 + 定时强制重启回退）→ 经批准后写分区。
- **ABL + DTBO 铁律**：RMX3370 ABL 按 `oplus,dtsi_no = <0x5473>` 选 DTB 并叠加原厂 `dtbo.img`；任何上机镜像打包前必须通过 `libufdt` 离线叠加校验、根身份校验与 AVB hash footer 自洽校验；占位符号一律放 `status = "disabled"` 无 compatible 无地址属性的容器中，严禁在调试通道就绪前访问外设寄存器。
- **去保守值原则**：除硬件额定/保护（如 2S 电芯规格与温区保护）、法规与防不可逆损坏外，不照搬厂商策略性限流/限频或社区盲目保守值；用户为 24/7 服务器主动要求的防鼓包充电上限按用户策略实现。
- **不带承重调试参数进产品**：不得将 `clk_ignore_unused`、`pd_ignore_unused`、`iommu.passthrough=1` 带入正式启动配置。
- **临时方案必须登记**：任何过渡做法在同一提交内记入 `docs/tech-debt.md`（原因、影响、退出条件）。

## 5. 目录约定

- `/root/rmx3370-ubuntu/`：公开集成仓（`AGENTS.md`、`docs/`、`tools/`、`kernel/`、`device/`、`packaging/`）。
- `/root/rmx3370-ubuntu/sources/`（git 忽略）：只读上游/社区参考仓库（如 `linux-sm8250`）。
- `/root/rmx3370-ubuntu/out/`（git 忽略）：长期内核 OUT 目录与构建产物。
- `/root/rmx3370-ubuntu/private/`（git 忽略）：本机固件、EFS、日志与唯一数据。
- `/root/ut-work/ref/`（只读参考）：此前取证的原厂 RUI 3.0 镜像、日志与驱动绑定清单。
- `/root/ut-work/port-bitra/kernel-src/`（只读参考）：原厂 4.19 内核源码（含 `oplus_mp2650.c`）。

## 6. 提交署名规则

- 第三方导入提交保留原作者、日期与来源提交链接，不加 AI 尾注；本地修改另成小提交。
- AI 完成的提交如实标注实际使用的工具/模型 `Co-Authored-By`，不伪造人类 `Signed-off-by` / `Tested-by`。
