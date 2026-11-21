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

## 2026-11-16 · 26.11 线：WiFi 根因定位（已解）+ 冷启动未通过（待查）

**假设**：26.11 上 wlan0 一直 `unavailable`，怀疑是 WiFi 上电链路没跑起来。

**唯一变量**：WiFi 栈实现（NetworkManager → wpa_supplicant），逐项读日志定位。

**判据（事先写死）**：L1 `PCIe Gen.3 x1 link up`；L2 `ath11k_pci ... wcn6855 hw1.1`；
L3 `/sys/class/net/wlan0` 出现并能拿到 192.168.0.150。

**结果**

1. L1/L2 一直正常，L3 不满足。NetworkManager 日志给出确切原因：
   `Couldn't initialize supplicant interface: Failed to D-Bus activate wpa_supplicant service`；
   改走 `networking.wireless`（wpa_supplicant）后，unit 启动失败于
   `Failed to set up mount namespacing: /dev/rfkill: No such file or directory`，
   `Main process exited, code=exited, status=226/NAMESPACE`。
2. 内核侧证据：`zcat /proc/config.gz | grep RFKILL` → `# CONFIG_RFKILL is not set`，
   `/dev/rfkill` 不存在；而 nixpkgs 的 `wpa_supplicant.service` 把 `/dev/rfkill`
   写死在 `BindPaths` 里。
3. 修复验证：25.05 用户态下 switch 到 26.11 闭包，手动
   `mknod /dev/rfkill c 10 242` + `systemctl restart wpa_supplicant` →
   `wlan0 UP 192.168.0.150/24`，`iw dev wlan0 link` 报 2401.9 MBit/s 160MHz
   HE-MCS11 NSS2，SSH 可用，`systemctl --failed` 空。L3 通过。
4. 另一个独立缺陷：`/etc/venus-wifi-setup` 第 24 行
   `nmcli connection up <WIFI_SSID>` 的占位符导致脚本语法错误，上电逻辑后半截不执行。已修。

**未通过的一步（本轮失败，标记为无效实验）**

把 `boot.img` 的 `init=` 从闭包绝对路径改成 `/nix/var/nix/profiles/system/init`、
profile 指向 26.11 闭包 `4n9rca37…` 后冷启动：设备黑屏，无 ping、无 COM3、
Windows 侧 fastboot 也看不到设备。**没有串口日志，无法判定死在哪一段**，
按实验纪律记为无效实验，不据此下任何结论。

**回滚**：`fastboot flash boot_b boot-1025c.img`（md5 `4A80CD35…`）+ reboot，
已验证 3 次回到 25.05 + WiFi + 串口。

**下一步**：先进 fastboot 刷回 `boot-1025c.img` 取得串口，再在 25.05 下
用同一内核/initrd 组合逐步验证 26.11 闭包的 stage-2 是否真能起、
`boot.initrd.systemd.services.venus-serial` 是否生成了 gadget。

## 2026-11-17 26.11 冷启动系列（全部失败，附原因归类）

| # | 六件套 / 做法 | 结果 | 结论 |
|---|---|---|---|
| 1 | 26.11 闭包 + fastboot boot.img（`init=` 指设备上不存在的闭包） | 全暗，无 COM | **无效实验**：stage-1 找不到闭包会自己扫盘挑一个，实际跑的是旧闭包 `fsr1cmy9` |
| 2 | 同上 ×2（boot-wifi / boot-defer） | 全暗 | 同上，仍然跑旧闭包；我的三次"修复"从未执行 |
| 3 | 26.11 旧闭包 `fsr1cmy9` 正常冷启动 | 有 COM、stage-2 起来、`wpa_supplicant active`、`0 failed units`，但 `ip addr` 只有 `lo` | 有效实验：`journalctl -b \| grep -c pcie` = **0**，`qcom-pcie` 整场未 probe → 无 wlan0 |
| 4 | 新闭包 `2zhn169g` 用 **kexec** 从 25.05 跳入 | 全暗，无 COM | 无效实验：kexec 路径下连 initrd 的 gadget 都没建起来，无法判断闭包好坏 |
| 5 | rescue6（initrd 内 root shell） | 稳定，能在 COM6 上跑命令、只读挂载 rootfs | **有效取证手段**，落盘日志链路可用 |

关键教训：
- 刷 boot.img 之前必须确认 `init=` 指的闭包 `nix-store --check-validity` 通过、确实在设备上；否则 stage-1 会静默回落到别的闭包。
- 用 kexec 做 A/B 在这台机上不可靠（本次无 COM、无任何日志），boot.img 才是唯一可靠入口。
- 26.11 的真实卡点是 PCIe 不 probe；判定证据是 `journalctl -b | grep -c pcie` 与 `cat /sys/kernel/debug/devices_deferred`。

## 2026-11-17 14:53 26.11 新闭包 si5mkkj9 冷启动（boot_b dd，全程自服务）

六件套：kernel+initrd+dtb 全部来自 si5mkkj9；cmdline `init=/nix/store/si5mkkj9…/init`，
`loglevel=8`。boot_b 由 25.05 侧 dd 写入并回读 md5 一致（f821865d…），未用 fastboot。

结果：重启后 3 分钟内 ping 全无、**COM 全无**（initrd 的 ACM gadget 都没出现）。

与之前 fsr1cmy9 那几次（有 COM、stage-2 起、只是没 wlan0）相比，这次连 initrd 都没到，
说明差异在**新构建的内核本身**（本次 config 加了 PSI/BPF_LSM/AUTOFS4/EROFS/VXLAN/
CHECKPOINT_RESTORE/APPARMOR/HARDENED_USERCOPY/FORTIFY_SOURCE），而不是用户态脚本。

下一步必须先做「变量隔离」：
1. 新内核 + 25.05 initrd + init=25.05 → 若能起 WiFi，说明新内核可用，问题在 26.11 initrd；
2. 旧内核（手编）+ 26.11 initrd + init=26.11 → 若能起 COM，说明问题在内核 config 新增项。

本次同时修复了一个真 bug：`/etc/venus-wifi-setup` 里 `$D` 从未定义（脚本 `set -u`），
导致 PCIe unbind/bind 兜底重训**从未执行过**；已补 `D=/sys/bus/platform/drivers/qcom-pcie`，
并新增 `regulator-wlan-en-ctl` 使能（exp1 已证明缺 wlan_en 时芯片完全不上电）。

## 2026-11-18 26.11 WiFi 打通（有效实验，里程碑 M2）

| 项 | 值 |
|---|---|
| 假设 | 26.11 上 `wlan0` 不出现/不通，是用户态配置问题，不是内核或 DTB |
| 唯一变量 | `20-wlan0.network` 合并 MAC 后重建闭包（其余五件同源） |
| 六件套 | kernel/initrd/dtb 全部来自 `kh69hbzs…`；`init=kh69hbzs…/init`；boot.img md5 `b27358a998499649de58f4b19cad5b34` |
| 判据 | L1 `wlan0` 目录存在；L2 有 IPv4 `192.168.0.150`；L3 SSH 可登录 |
| 结果 | L1/L2/L3 全通过，冷启动 2/2 |
| 结论 | 成立 |

关键日志原句：

```
systemd-networkd[466]: wlan0: Configuring with /etc/systemd/network/10-wlan0.network.
systemd-networkd[466]: wlan0: Connected WiFi access point: moli-1004-backup (be:fc:e7:9e:e8:d5)
wpa_supplicant[737]: wlan0: CTRL-EVENT-CONNECTED - Connection to be:fc:e7:9e:e8:d5 completed
ath11k_pci 0000:01:00.0: wcn6855 hw1.1
ath11k_pci 0000:01:00.0: fw_version 0x11008104 ... WLAN.HSP.1.1.c3-00260-...
```

反证：`ip -br addr show wlan0` 在修复前只有 IPv6（`fc00:…`、`240e:…`），
说明链路与关联都正常，缺的只是 IPv4 —— 因此此前所有"WiFi 没通"的判断都被这一条污染过。

## 2026-11-18 deadman 秒退（无效自动化，已修）

`venus-deadman.service` 每次在启动同一秒 `status=1/FAILURE`。原因：systemd 的 unit-script
带 `set -e`，而 `ip4=$(ip -4 … | grep -c 'inet ')` 在零匹配时 `grep` 返回 1，赋值失败即退出。
修法 `grep -c … || true`（闭包 `k6hxwm70`，已构建未部署）。
这是本轮之前反复需要人工进 fastboot 的直接原因。

## 2026-11-18 「开机几分钟就失联」的真因：deadman 误判（有效实验，已修）

| 项 | 值 |
|---|---|
| 现象 | WiFi 已连上（PING/SSH 正常、`iw link` 2401.9 MBit/s），设备仍在 4~5 分钟后自己重启 |
| 唯一变量 | 修 deadman 的 IPv4 检测方式 |
| 判据 | `/persistent/venus-deadman.log` 出现 `ip4=1`，且 10 分钟不回滚 |
| 结果 | 通过（闭包 `9a8mifab`；`ip4=1`，uptime 826s 仍在线） |

根因两条，都在 deadman 的判定里：

1. `ip -4 -br addr show` 的简要输出**没有** "inet" 字样
   （`wlan0            UP             192.168.0.150/24`），`grep -c 'inet '` 恒为 0 →
   永远判"无网" → 3 次后回滚重启。改用 `ip -4 addr show dev wlan0`。
2. `grep -c` 零匹配返回 1，配合 unit-script 的 `set -e` 会让脚本秒退；已加 `|| true`。

附：WiFi 认证抖动（同一现象的另一半）——AP 对该 SSID 广播两个 BSSID，
`…:d5` 可用、`…:d4` 认证不过；nixpkgs 为同一 SSID 生成两条 network 块
（一条含 SAE/FT-SAE）+ 全局 `pmf=1`，客户端会黏在 `…:d4` 上反复重试。
已改为单一 network 块并钉死 `bssid=be:fc:e7:9e:e8:d5` + `scan_freq=5180`，
实测 `journalctl -b | grep -c "e8:d4"` = 0。

## 2026-11-18 OTG 实验（结论：放弃，硬体风险）

| # | 假设 | 唯一变量 | 结果 | 结论 |
|---|---|---|---|---|
| 1 | dwc3 改 host 后 xHCI 能起来 | `dr_mode` peripheral→host（其余不动） | ✅ `lsusb` 出现 USB2(480M)/USB3(10000M) 两个 root hub，`dmesg` 有 xhci 7 行；WiFi 与启动均正常 | 成立 |
| 2 | 端口需 VBUS 才能枚举外设 | 加 `regulator-fixed`(pm8350 gpio8)+`regulator-always-on` | ❌ 黑屏、USB 全无、需人工进 fastboot | 无效实验（且危险） |
| 3 | VBUS 改为用户态可控（默认关） | `regulator-output` 包一层，`echo enabled` 打开 | ✅ `regulator-usb-vbus-ctl/state` 可写，`gpio8` 变 `out high`；但插 U 盘仍不枚举 | 部分成立：供电路径通了，枚举仍不通 |

关键分析：
- `dr_mode=host` 单独改是安全的，可作为将来参考（xHCI 正常）。
- 危险点在 VBUS：手机接 PC 时 PC 也在供 5V，`always-on` 造成两端对顶，
  触发端口保护 → 整机黑屏。这类实验必须断开 PC 数据线、用电池供电。
- 第 3 步即使供电开到位，插 U 盘仍无 `new high-speed USB device`，说明还缺
  vendor 侧的角色/ID 或 boost 时序（vendor 走 `extcon_usb1` + `usb2_vbus_boost`
  的 pinctrl 默认 `output-low` + 运行时切换），继续排查需要直接驱动 PMIC 供电电路。
- **用户明确不接受烧机风险，OTG 整项终止。** 仓库 DTS 与设备 boot 均回到
  `dr_mode = "peripheral"`（里程碑镜像 md5 `70e14e69afb887b924b2f9aba02f0110`）。

---

# 2026-11-19 根文件系统迁到 fleet 布局（tmpfs / + btrfs /nix）

六件套登记（三轮，闭包逐轮变化，kernel/dtb 始终同一份）：

| 轮次 | 假设 / 唯一变量 | 六件套 | 判据 | 结果 |
|---|---|---|---|---|
| A | 手拼 boot.img 的 cmdline 也能起 | 闭包 `lzwjmv8x`、kernel `7.2.6`、dtb `527c521e…`、boot.img `a3f911fe…`（cmdline **无** `root=fstab`）、dtbo_b 全零 | L1 串口 COM3 出现；L2 `wlan0`；L3 ping 192.168.0.68 | ❌ 三者全无，连 emergency shell 都没有（`venus-serial` 被 `initrd.target` 的 OnFailure 取消） |
| B | 只补 `root=fstab` 就够 | 同 A，仅 cmdline 换成 `tools/boot-img.sh` 生成的 `e714d59c…`（含 `root=fstab`） | 同上 | ✅ 15:07 启动到登录终端（证明 A 的唯一差异 = cmdline） |
| C | WiFi 失败是 AP 换信道 + psk 过期 | 闭包 `s0yms7ir`（去 `scan_freq`、`/persistent`→`/nix/persistent`、initrd 落盘修 bug）→ 再 `ikdxzx04`（grow 改 btrfs resize） | `wlan0 UP 192.168.0.68`，`iw link` 有速率 | ❌ 仍不通：`WPA: 4-Way Handshake failed - pre-shared key may be incorrect`、`WRONG_KEY` |

C 轮的决定性证据（同一台设备，串口里读到的原句）：

```
wlan0: Trying to associate with be:fc:e7:9e:e8:d5 (SSID='moli-1004-backup' freq=5300 MHz)
wlan0: Associated with be:fc:e7:9e:e8:d5
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-SSID-TEMP-DISABLED id=0 ssid="moli-1004-backup" auth_failures=11 duration=120 reason=WRONG_KEY
```

- 「去掉 `scan_freq`」这条单独成立：改动后第一次就能 `Associated`（频段 5300），
  而之前是连扫都扫不到 —— 两个症状不同，是两条独立问题。
- psk 用**另一台已连上该 AP 的机器**（本机 NetworkManager 的 `moli-1004-backup.nmconnection`）
  对照：本机 8 字符，仓库里 25 字符，`DIFFERENT`。把本机那份写进 `configuration.nix` 后，
  设备上手动起 wpa_supplicant 立刻 `Connected to be:fc:e7:9e:e8:d5 … signal -32 dBm`，
  并且 `ip -4 -br addr show wlan0` 出现 `192.168.0.68/24`（networkd 静态地址自动生效）。

D 轮（最终验收）：闭包 `ikdxzx04…`、boot.img `c04066f9…`，冷启动后
`/`=tmpfs、`/nix`=btrfs+compress-force=zstd（225G）、`wlan0 UP 192.168.0.68/24`、
`systemctl --failed`=0、`udc=configured`/`ttyGS0` 存在、`MHI_CB_EE_RDDM`=0。
日志：`~/venus-logs/20261119-1600/`。

## 2026-11-21 · GPU（Adreno 660）

| 轮 | 假设 | 唯一变量 | 六件套 md5 | 判据 | 结果 |
|---|---|---|---|---|---|
| G1 | GPU 起不来是"固件找不到/加载时机"问题 | 固件落到 `qcom/`（含 zap）+ `msm` 从 initrd 移到 stage-2（同一件事的两半：`firmware_class.path=/run/current-system/firmware` 只在 stage-2 存在，拆开做没有意义） | 闭包 `i92ci8lcb…`、kernel 7.2.6（fleet 预编译 v0.1.0）、initrd 新（无 `msm.ko`）、dtb `527c521e…`、boot.img `6bc9157c…` | dmesg 出现 `loaded qcom/a660_sqe.fw` / `a660_gmu.bin`，且无 `gpu hw init failed` | 🔶 部分成立：sqe/gmu 载入、`Loaded GMU firmware v3.1.8`，但 `Unable to load a660_zap.mdt` → `gpu hw init failed: -2` |
| G2 | zap 找不到是因为 DT 的 `firmware-name` 少了 `qcom/`（adreno 读到该属性后直接 `request_firmware_direct()`，不走 qcom/→legacy 兼容） | 只改 DTS 一行：`&gpu_zap_shader { firmware-name = "qcom/a660_zap.mdt" }` | 同 G1，仅 dtb `51c4f6dd…`、boot.img `7cc56d7d…` | zap 载入且 glmark2 出分 | ✅ `vulkaninfo` = `Turnip Adreno (TM) 660`；`glmark2-es2-drm -b :duration=1` Score **188**，多数场景 190~230 FPS |

G2 的决定性日志（`dmesg`，同一台设备）：

```
[   11.955828] msm_dpu ae01000.display-controller: [drm:adreno_request_fw [msm]] loaded qcom/a660_sqe.fw from new location
[   11.957905] [drm] Loaded GMU firmware v3.1.8
[   12.219523] msm_dpu ae01000.display-controller: [drm] fb0: msmdrmfb frame buffer device
```

- G1 的失败句：`adreno_zap_shader_load: Unable to load a660_zap.mdt` 紧接
  `adreno_load_gpu: gpu hw init failed: -2` 与 `a6xx_gmu_set_oob: Timeout waiting for GMU OOB`。
- 显示在 G1/G2 都正常（DPU/DSI 与 GPU 固件无关），所以"屏幕上没花屏"不能当作 GPU 成功的判据。
- 回滚镜像：改动前设备 boot_b 整份留在 `out/boot-prev.img`（md5 `6f33dd3a…`）。
