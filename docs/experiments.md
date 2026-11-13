# 实验登记表

纪律见 `AGENTS.md` §6（单变量）与 §7（日志）。六件套 md5 缺一项即视为无效实验。

## 当前状态（2026-11-13 21:20）

| 项 | 值 |
|---|---|
| `boot_b` | F 镜像（`19976beee118cc8e88148b5521cc2807`），跑起来后不可达 |
| 设备 state | `none`（ping / 22 / 2222 / fastboot 全无；Windows `18D1=0`、`COM=0`） |
| 回滚镜像 | `/persistent/root/*.img` 已全部改名 `*.disabled`，不会再覆盖 `boot_b` |
| 观测 | `venus.debug.enable = true`；stage-1 dump / stage-2 journal / pstore 全部落盘 |

## 基线（已知可用的参照物）

| 件 | 值 |
|---|---|
| 救援系统闭包 | `3kzw2kh75n7cgrc66xg9vp42jcbs0czj-nixos-system-venus-25.05.20260102.ac62194` |
| 救援内核 Image | `8b2924094ca196c92fcba2823c8e6868`（= `~/.cache/venus-kernel/linux-build` 的产物） |
| 救援内核 DTB | `fecd5b9962584837f834d2c118eb6ef8` |
| 救援表现 | 桌面可用、**WiFi 正常（本会话全程靠它取日志）**、Windows 侧看不到其 USB |

## 已排除（附证据）

| 假设 | 结论 | 证据 |
|---|---|---|
| kernel-config 的 13 项增量（RFKILL/ZRAM/MPTCP/NFT/WIREGUARD 等） | 排除 | 用冻结内核内嵌 config 重建仍崩；且救援 config 与我们只差这 13 行 |
| debug 内核项与 console 洪泛 | 排除 | cmdline 退回 `loglevel=7` 仍崩 |
| nix `manualConfig` 构建路径 | 排除 | 老流程纯 `make` + 交叉 gcc 重建仍崩 |
| 编译器/工具链版本 | 排除 | 三个内核 `Linux version` 行都是 GCC 15.3.0 + binutils 2.46 |
| 补丁漏打 | 排除 | 补丁自检通过；日志认到 `wcn6855 hw1.1`、chip_id、fw_version |
| 本地树有未提交改动 | 排除 | 缓存树 vs 纯净 7.2.6 全量 diff，只有补丁脚本改动 |
| 固件文件不同 | 排除 | 两闭包 `ath11k/WCN6855/hw1.1` 各文件字节数一致 |
| BT 固件缺失 | **已修** | 旧闭包有 `qca/wcnhpbtfw10.tlv`、现闭包缺；补入真实文件后日志变为 `QCA Downloading …` 成功 |
| DTB 差异 | 排除 | E2：只换救援系统 DTB（`fecd5b99`）仍失败（21:01 轮） |
| 用户态 WiFi 脚本干预 | 排除 | F：`venus-wifi-power` / `venus-wifi-check` 默认关闭仍失败（21:11 轮） |
| 回滚镜像覆盖 `boot_b` | 排除 | 三个 `*.img` 已改名，E2/F 两轮仍失败 |
| 符号级内核差异 | 排除 | 11-09 构建与复现构建 `System.map`：183234 符号、顺序一致、代码符号跨距零差异 |
| `wlan_en` pinctrl 有害 | 排除（且证明必需） | exp1：删掉后 WiFi 芯片根本不上电、无 PCIe 端点 |

## 未解决

| # | 假设 | 下一步做法 |
|---|---|---|
| H1 | **Type-C 端口在 Linux 下处于 host/source 角色**，导致 USB device 模式永不枚举（串口拿不到、`18D1=0`） | 进救援读 `/sys/class/typec/*`、`/sys/class/usb_role/*/role`、`dmesg \| grep -iE 'typec\|ucsi\|altmode\|dwc3'`；再尝试 `echo device > /sys/class/usb_role/a600000.usb-role-switch/role` |
| H2 | 自建内核与 11-09 内核在运行期不等价（尽管符号表一致） | 把 11-09 的 Image + `modinst` 模块树接进闭包，做真正的 A/B |
| H3 | ath11k 固件崩与 WCN6851 供电时序（`wlan_en`/`bt_en` 与 PCIe 上电顺序）相关 | 需要 H1 打通后用串口在设备里逐项开关验证 |

## 实验记录

| 时间 | 唯一变量 | 结果 | 结论 |
|---|---|---|---|
| 11-13 14:19 | debug 内核 + debug cmdline | `firmware crashed: MHI_CB_EE_RDDM` ×3 | 崩因不在 debug 开关 |
| 11-13 14:55 | 冻结内嵌 config 重建内核 | 同上 | config 增量排除 |
| 11-13 16:07 | 老流程 `make` + 冻结 config | 同上 | 构建路径排除 |
| 11-13 16:16 | 自建内核 + 证明版 DTB | 同上 | DTB 不是唯一原因 |
| 11-13 16:40 | exp1：删 `wlan_en` pinctrl | 系统正常到 `network.target`，但无 PCIe 端点、无 BT 固件下载 | pinctrl 必需 |
| 11-13 17:07 | 复现内核（缓存树 + 证明 config + 内嵌 initramfs） | Image 尺寸与证明版逐字节相同；initrd 阶段 `initrd-find-nixos-closure` 失败 → emergency | 内嵌 initramfs 破坏闭包发现 |
| 11-13 17:24 | 复现内核 + 加 `/bin` 预置 shim | `initrd.log` 无新内容（顺序环把 initrd 卡死） | 无效实验（自我 bug），已移除该 shim |
| 11-13 20:15 | C：补 QCA 固件 + 交叉内核 + debug 观测 | 进到 stage-2、桌面；`venus-acm: UDC=a600000.usb state=configured`；ath11k 仍崩 | 固件补齐有效；串口在设备侧起来过 |
| 11-13 20:36 | 去掉 PCIe 重训循环 + wifi-check 只记录 | 12×20s ping 全 down，无日志 | 无效实验（拿不到日志） |
| 11-13 21:01 | E2：只换 DTB 为 `fecd5b99` | 12×20s ping 全 down，`18D1=0` | **DTB 排除** |
| 11-13 21:11 | F：关掉 wifi-power / wifi-check | 12×20s ping 全 down | 用户态干预排除 |

## 资产

- `~/.cache/venus-kernel/linux-build/`：11-09 构建的完整产物 —— `vmlinux`(150MB)、
  `System.map`(7.5MB)、646 个 `.ko`、`Image`(43325952，md5 `8b292409`)、`.config`、
  逐文件的 `.cmd`。**这份 Image 就是救援系统正在跑的、WiFi 正常的那个内核。**
- `~/.cache/venus-kernel/modinst/`：由上面这棵树 `make modules_install` 出来的模块树
  （`lib/modules/7.2.6/`，646 个 `.ko` + `modules.dep`），与 `8b292409` 的 vermagic 匹配。
- `repro/`：复现构建（缓存树源码 + 指定 config + 可选内嵌 initramfs），输出
  `Image`/`venus.dtb`/`config`/`System.map`/`vmlinux`。
- `~/venus-logs/20261113-1621|1643|1709|1905|1918|2025/`：各轮完整 journal 与 `venus-debug/`。

## 下一步队列（按优先级）

1. **H1：读 Type-C / usb_role 状态**（需一次 fb，只读，不刷机）。这是解锁串口的关键，
   串口一通后续所有 WiFi 调试都能在设备里做。
2. H2：把 `linux-build` 的 Image + `modinst` 接进闭包做内核 A/B（需解决 kernelPackages
   接线；先做，不占用设备轮次）。
3. H3：WiFi 供电时序验证（依赖 1）。
