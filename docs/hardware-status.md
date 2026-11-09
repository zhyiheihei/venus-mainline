# venus（小米 11 / SM8350）硬件适配情况与计划

更新时间：2026-11-09。所有"可用/不可用"都尽量附当天在设备上取到的输出，不接受"应该可以"。

当前基线：NixOS 25.05，内核 `7.2.6 #52 (2026-10-28)`，profile `9nv5kxlx…`，
SSH `root@192.168.0.150`（WiFi），串口通道 `console=ttyGS0` 由 `venus-acm` 服务维持。

---

## 1. 总览

| 子系统 | 状态 | 依据（实测） |
|---|---|---|
| 启动（boot_b + ABL 注入内存） | ✅ 可用 | `memory` 全零占位；冷启动到桌面 |
| 显示（DSI 命令模式 + K2 AMOLED） | ✅ 可用 | `card1-DSI-1` connected/enabled，1440x3200，画面持续刷新 |
| 背光 | ✅ 可用 | `/sys/class/backlight/ae94000.dsi.0`，max 255，当前 39 |
| 触摸（ST FTS over SPI） | ✅ 可用 | `venus-fts-ts`，`Handlers=event3` |
| GPU（Adreno 660 / freedreno+turnip） | ✅ 可用 | `glmark2-es2-wayland 1440x3200` = 904；Vulkan = Turnip Adreno 660；GMU fw v3.1.8 |
| UFS | ✅ 可用 | `/dev/sda` 235.2G，根分区 ext4 |
| WiFi（WCN6851 / ath11k） | ✅ 可用（有前提） | `wlan0` + 192.168.0.150，`iw link` 5300MHz/-14dBm，50 包 0% loss |
| 蓝牙（WCN6851 over UART） | ✅ 可用 | `hci0 UP RUNNING`，`bluetoothctl scan on` 扫到 8 个设备 |
| 电池/充电（pmic-glink + qcom_battmgr） | ✅ 可用 | `qcom-battmgr-bat` capa 100%，`-usb online=1`，usb_type 枚举 SDP/DCP/PD… |
| 温度传感器 | ✅ 可用 | 41 个 thermal zone（cpu7-top/gpu-top/aoss…） |
| CPU（8 核）/ 调频 | ✅ 可用 | `nproc=8`，devfreq cur_freq 有值 |
| 电源键 / 音量上键 | ✅ 可用 | `pmic_pwrkey`（KEY_POWER）、`gpio-keys`（KEY_VOLUMEUP） |
| 音量下键 | ⚠️ 未绑定 | DTS 里 gpio-keys 只有 volume_up |
| 振动马达（AW8697） | ❌ 未启用 | vendor overlay 有 `aw8697@0x5a`（i2c6, reset=gpio155, irq=gpio119），内核无驱动、DTS 无节点 |
| NFC（SN100） | ❌ 未启用 | vendor overlay 有 `sn-nci@28`（irq=gpio87），无驱动/无节点 |
| 摄像头（CAMSS/CCI + 多摄） | ❌ 未开始 | `dmesg` 里 `camss|cci|imx` 命中 0；`/dev/video*` 数量 0 |
| 基带 / 通话 / 移动数据 | ❌ 未开始 | `&mpss` 在 DTS 里 `disabled`；无 `/dev/wwan*` |
| 传感器（加速度/光距/陀螺） | ❌ 未开始 | 唯一的 iio 设备是 `c440000.spmi:pmic@0:adc@3100`（PMIC ADC，不是运动传感器）；vendor overlay 里也没有节点 |
| 红外发射 | ❌ 主动放弃 | 驱动+DTB 已就绪（`ir-spi` + spi1/gpio8-11），但内核改动会连带 WiFi 失效 |
| USB OTG 接键鼠 | ❌ 未验证 | DTS/配置已按 `sm8350-hdk.dts` 写好并编进内核，但该内核起不来；当前系统 `typec`/`usb_role` 类均为空（角色切换驱动没编进来） |
| USB 设备模式（ACM 串口） | ✅ 可用（有条件） | `venus-acm` 重建 gadget；Windows 侧需 `pnputil /scan-devices` 或拔插才枚举 |
| 休眠 / 唤醒 | ❌ 会复位 | `rtcwake -m freeze -s 15` 后设备直接复位（新 boot id、uptime 0:00） |
| 音频 | ❌ 不做（用户决定） | CS35L41 功放已黑名单（它的 IRQ 风暴会让整机卡死） |

---

## 2. 三个"必须知道"的非标准点

### 2.1 DTS 的 `memory` 必须留空

`memory { reg = <0 0 0 0>; }` —— 内存布局由 ABL 按实际 DDR 容量注入。写死旧 8GB 机布局
在新机上一秒内死（卡米标 + USB 零枚举）。另外 reserved-memory 有 9 处必须用手机真实 DT 的值
覆盖主线（xbl_aop / pil_adsp / pil_slpi / pil_cdsp / ipa×3 / spss / modem / removed_mem /
splash + dfps），逐条对照见 `docs/audit-sm8350.md`。

### 2.2 WiFi 供电在用户态开

五路电源写成 `regulator-output`（userspace-consumer），由 `/etc/venus-wifi-setup`
按厂商时序 `echo voltage/state`；写进设备树做 `always-on` 会导致开机挂死（实测 3 次）。
这条路的两个硬依赖：

1. 内核补丁 `userspace-consumer`（非独占 get、容忍 `is_enabled()` 返回负值）；
2. `wlan_en`(gpio64) / `bt_en`(gpio65) 的 pinctrl（厂商 DT 有、主线没有）。

缺任一个的表现都是"WiFi 全哑 + PCIe 端点不枚举"，很容易被误判成 PCIe 硬件问题。

### 2.3 内核补丁必须脚本化

`tools/apply-kernel-patches.sh`（幂等 + 末尾自检）覆盖：面板驱动、触摸驱动、pcie 重训
（去 `suppress_bind_attrs` + 加 `remove`）、userspace-consumer、dpu vsync 四舍五入、
qcom_battmgr 属性屏蔽、ath11k WCN6851。
这些补丁曾经只存在于临时源码树，树一重建就全丢——那正是"重建内核必挂 WiFi"的真因。

---

## 3. 当前唯一的拦路虎

**重建内核不可用**。逐层排掉之后只剩一层：

```
ath11k_pci 0000:01:00.0: Unsupported WCN6855 SOC hardware version: 1 16   → 补丁已补
（补丁生效后）该内核进不到用户态：ABL 停回 fastboot，无 journal、无 /sys/fs/pstore
```

前一层已经用日志证明修好了（PCIe `link up` + 端点 `17cb:1103` 枚举 + `wlan0` 在
"工作版内核 + 新 DTB" 组合下正常）。后一层需要**early boot 的串口输出**才能定位。

而串口目前拿不到：手机 USB 口在 Windows（PVE 直通）与本机笔记本上都不枚举，
`/dev/ttyACM*` 与 `VID_18D1` 都没有。这是纯物理层问题（线/口），必须先解决。

---

## 4. 计划

### P0：恢复可迭代能力（无风险，不需要改内核）

1. **打通串口**：换数据线 / 换 USB 口，确认不是充电线；插上后任一台主机应看到
   `VID_18D1&PID_4EE1`。Windows 侧先 `C:\Windows\System32\pnputil.exe /scan-devices`。
   一旦有串口，后续所有内核实验都能自取证，不再需要人肉 fastboot。
2. **把失败现场变成自动的**：已完成——`venus-wifi-fallback` 会在开机 90s 没 WiFi 时
   写 `/var/log/venus-bootfail.log` 并 dd `/root/boot_b-good.img` 回 boot_b（≤5 次）。
   刷任何实验内核前确认 `/root/boot_b-good.img` 是当前工作版。

### P1：解开重建内核（唯一需要串口的事）

1. 串口在手后，刷一次候选内核，抓 `ath11k` 在 WCN6851 路径上的完整调用栈；
2. 对照上游 `wifi: ath11k: enable support for WCN6851` 系列（Dmitry Baryshkov），
   逐条比对我的最小实现（`core.h`/`pci.c`/`mhi.c`/`pcic.c`/`core.c`），补齐缺失项
   （可能缺 HAL desc ops 或 `hw1.1` 特有的 `internal_sleep_clock` 等）；
3. 通过后立刻把该配置定为新基线，并按记忆中的规矩：验证一次就提交、记录镜像与参数。

### P2：能改内核之后（按价值排序）

| 顺序 | 项目 | 预估工作量 | 风险 |
|---|---|---|---|
| 1 | USB OTG 接键鼠（DTS/配置已就绪，只需验证） | 一次刷机 | 低（默认仍 peripheral，串口不丢） |
| 2 | 音量下键（`gpio-keys` 加一项，抄 vendor DT 的 gpio） | 一次刷机 | 低 |
| 3 | 振动马达 AW8697（内核有 `aw86927.c`，需 i2c 节点 + 波形文件） | 中等 | 中（固件/波形来源） |
| 4 | NFC SN100（`nfc/nxp-nci` 在主树里） | 中等 | 中（i2c 地址/固件/SE 配置） |
| 5 | 休眠（先查 `mem_sleep` 与 PDC 唤醒源） | 大 | 高（点了会复位，需串口） |
| 6 | 传感器（先确定 venus 用的具体型号与总线） | 大 | 高（vendor overlay 无节点，信息不足） |
| 7 | 摄像头 / 基带 | 很大 | 很高（CAMSS 主线支持有限；modem 需要 QMI 栈） |

> 红外已按用户决定放弃；音频不做（CS35L41 保持黑名单）。

### P3：不需要动内核的收尾（随时可做）

- 亮度键/音量键映射到 Plasma 的快捷键（用户态即可）
- 装机流水线回归：`tools/install-venus.sh rootfs` 在磁盘路径上从头跑一遍
  （注意别用 `/tmp`，本机 `/` 与 `/tmp` 是 tmpfs，12GiB 镜像会整机 OOM）
- 把"第二台机器的完整流程"写成一次性可执行的 runbook（现在分散在 docs 里）

---

## 5. 关键运维口径（避免重复踩）

```bash
# 部署配置（不刷镜像）
tools/install-venus.sh deploy

# 只换内核（不需要 fastboot）
tools/build-kernel.sh                         # 基线=设备 /proc/config.gz
tools/make-bootimg.sh /tmp/boot-xxx.img       # KERNEL_IMAGE/DTB/INITRD 可覆盖
ssh root@<phone> 'dd if=/tmp/boot-xxx.img of=/dev/sde38 bs=1M conv=fsync; reboot'

# 失败回滚（设备内，无网也能用）
dd if=/root/boot_b-good.img of=/dev/sde38 bs=1M conv=fsync && reboot

# 构建环境
export NIX_CONFIG="substituters = http://192.168.0.56:13851 https://cache.nixos.org"
# gpg-agent 坏了会让所有 ssh 卡在等 banner：
env -u SSH_AUTH_SOCK ssh -o IdentityAgent=none root@<phone> true
```

刷机红线不变：绝不碰 `xbl*/xbl_config*/abl/tz/hyp/keymaster/devcfg/cmnlib*/qupfw/imagefv/
persist/modemst1/2` 与分区表；实验只动 `boot_b` 与 `userdata`；slot a 保留可回落系统。
