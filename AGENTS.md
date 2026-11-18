# venus-mainline 约定

<<<<<<< HEAD
小米 11（venus / SM8350）的 standalone NixOS。目标是系统跑通、WiFi 可用、串口可用，
日志里不留异常。fleet 角色在本机 standalone 清零前不碰。

## 当前状态（2026-11-18，里程碑 M2）

**系统已是 NixOS 26.11，WiFi 可用**（详见 `docs/milestones.md` 的 M2）。
闭包 `kh69hbzshy2838c2g6rhms8r63dkrckb`，boot.img md5 `b27358a998499649de58f4b19cad5b34`。

| 能力 | 实测 |
|---|---|
| WiFi（WCN6851） | `wlan0 UP 192.168.0.150/24`；SSID `moli-1004-backup`；2401.9 MBit/s / 160MHz / HE-MCS11 / NSS2；`ath11k_pci wcn6855 hw1.1` fw `0x11008104`；`MHI_CB_EE_RDDM` = 0 |
| 系统 | 冷启动 2/2，41 秒 ping 通；`systemctl --failed` = 0 |
| 串口 | 不可用（switch-root 后 UDC 回 `default`；PVE 未把该 USB 直通回 MOLI-VM） |
| OTG | 未做，下一里程碑 |

**调试一律走 WiFi SSH：`root@192.168.0.150`。** 串口不再是主通道。

三条容易重踩的坑：

1. `systemd-networkd` **每个 link 只用一个 `.network` 文件**（按文件名取第一个匹配）。
   把 MAC 放 `10-wlan0`、IPv4 放 `20-wlan0` 时只会应用前者 → 只有 IPv6、没有
   `192.168.0.150` → 看起来"WiFi 没通"，实际 wpa_supplicant 早已关联成功。
   MAC 与地址必须写在同一个文件里。
2. `venus.debug.enable = true` 会往 cmdline 注入 `rd.debug` / `loglevel=8` /
   `oops=panic` / `panic=30`，在唯一 115200 串口上等于把启动拖成分钟级，且任何 oops 变致命。
3. systemd 的 unit-script 带 `set -e`：`x=$(... | grep -c ...)` 在零匹配时会让整个脚本
   立刻退出（`venus-deadman` 因此每次都秒退，从未能自动回滚）。

## 0. 范围

- 只做 standalone（本仓库 `nixosConfigurations.venus`）。
- `nixos-config` 里 `hosts/venus` 与 fleet 相关配置一行不改。
- 不通过替换内核之外的系统组件来"绕过"硬件问题。

## 1. 工具是唯一入口

| 目的 | 命令 |
|---|---|
| 设备状态（state + 身份 + Windows 串口） | `tools/venus-state.sh` |
| Windows 侧 USB（fastboot / 18D1 / COM） | `tools/win-probe.sh` |
| fastboot（内置超时，无设备返回 3） | `tools/win-fastboot.sh devices` / `"flash boot_b C:/…"` |
| 从闭包组装 boot.img（cmdline 唯一来源） | `tools/boot-img.sh <closure> <out.img> [--dtb <dtb>]` |
| 部署（推闭包 + 切 profile + 可选写 boot_b + 重启） | `tools/deploy.sh <closure> [--boot-img <img>] [--no-reboot]` |
| 取回完整日志 | `tools/fetch-logs.sh [目录]` |
| 经 Windows COM 口给设备发命令 | `tools/serial.sh "<命令>" [秒]` / `--read` |

规则：

- 以上动作只能用这些脚本。禁止在 `/tmp` 或 `$HOME` 里另起一次性脚本，禁止手拼
  `mkbootimg` / `dd` / `nix copy` 序列；缺能力就往 `tools/` 加脚本，并更新本节。
- 禁止直接 `tools/win.sh "fastboot …"`：`fastboot` 找不到设备会无限等待，必须走
  `win-fastboot.sh`。该脚本做三件事：调前 `taskkill /IM fastboot.exe /F` 清残留、
  20 秒本地超时、调后再清一次。**必须前后都清**：超时只杀掉本地 ssh，Windows 上的
  `fastboot.exe` 会继续等设备，用户一插线就把旧命令跑掉——已经踩过一次，造成
  "重插后莫名执行了上一条 flash"。
- 只探测设备配置里的地址（`VENUS_IP`，默认 192.168.0.150）。禁止扫描网段内其它主机。

## 2. 单一 boot

`boot_b` 里只有一个 boot.img，是唯一引导入口，不为实验来回切换。

- 回滚镜像（`/persistent/root/*.img`）已全部改名为 `*.disabled`，不要再恢复。
- 换内核/DTB/initrd 属于单独一次需要明确批准的动作；换前记录当前 md5，换后不回切，
  除非该轮实验被判定失败并结案。

## 3. 部署优先（尽量不刷机）

内核、DTB、initrd 都在 `boot_b` 里，因此：

- **用户态变更**（服务、配置、包、WiFi 凭据、日志服务）→ 不刷机：
  `tools/deploy.sh <closure>`（推闭包 + 切 profile + 重启）。
- **只有内核 / DTB / initrd 变更**才重写 `boot_b`：`tools/deploy.sh <closure> --boot-img <img>`。

## 4. 设备操作状态机

| state | 含义 | 下一步 |
|---|---|---|
| `rescue`（ssh 22） | 旧版 standalone（25.05，带桌面，WiFi 正常） | 可 SSH，走第 3 节 |
| `fleet`（ssh 2222） | fleet 系统 | 同上（fleet 清零前不使用） |
| `fastboot` | Windows `fastboot devices` 有序列号 | 只能做第 2 节允许的动作 |
| `booting` | 有 ping 无 ssh | 等满 2 分钟再判 |
| `none` | ping/ssh/fastboot 全无 | 先 `win-probe.sh`；要动手才请用户进 fb |

- 失联判定 2 分钟，不提前宣布失败。
- 串口只在 Windows 端查；设备从不连接本机，本机 `/dev/ttyACM*` 永远为空。
- 刷写一律经 Windows 主机（`tools/win-fastboot.sh`）；本机 fastboot 不可靠。
- ABL 不认 misc 分区 BCB（`boot-fastboot` / `bootonce-bootloader` 实测无效）。

### USB / 串口（已打通）

- 关键改动：DTS 里把 `&usb_1_dwc3` 从 `dr_mode = "otg"` + `usb-role-switch` 改成
  `dr_mode = "peripheral"`，并 `&usb_1_dwc3_hs { status = "disabled"; }`。
  之前 OTG + pmic_glink 角色切换会把端口留在 host/source（`port0: data_role=host`），
  导致 gadget 永不枚举、USB 串口与 USB 网卡都不可用。
- 改完后 Windows 出现 `VID_18D1&PID_4EE1` 与 `COM3`，`tools/serial.sh` 可直接跑命令。
- ABL/fastboot 下 Windows 能看到 `18D1:D00D`；从 fastboot 切到 Linux 或反向切换时，
  Windows 可能不重新枚举，需要重插一次数据线（已知限制）。
- 因此：设备在 gadget 之间切换后（ACM ↔ fastboot），Windows 可能不重新枚举，
  需要**重新插拔一次数据线**。这是已知限制，不是脚本 bug。

## 5. 六件套一致性

一次启动由六件决定，必须同源并登记 md5：kernel / dtb / initrd / `init=` / profile / cmdline。

- 禁止混用不同闭包的内核与 initrd（vermagic 不匹配 → 花屏、无日志）。
- 改 `init=` 前必须先把闭包 `nix copy` 到设备（switch_root 失败时 stage-2 零日志）。
- `tools/boot-img.sh` 已保证 kernel/dtb/initrd/`init=`/cmdline 同源，禁止绕过。

## 6. 实验协议（单变量）

每轮在 `docs/experiments.md` 记一行：假设 / 唯一变量 / 六件套 md5 / 判据 / 结果 / 结论。

- 一轮只改一个变量，其余 md5 必须与上轮相同，否则本轮作废、不写结论。
- 判据事先写死，三级：L1 `ath11k` 有无 `firmware crashed: MHI_CB_EE_RDDM`；
  L2 `/sys/class/net/wlan0` 是否出现；L3 能否拿到 IP。
- 假设被证伪要留档，不再重试同一组合。
- 拿不到日志的轮次标记为"无效实验"，不得据此下结论。

## 7. 日志纪律

默认动作是把**完整**日志拉回本机，而不是 grep 几行（此前因只看局部导致结论偏差）。

1. 失败后进 rescue，`tools/fetch-logs.sh` 取回 `~/venus-logs/<时间戳>/`：
   `/persistent/var/log/journal` 整目录 + `/persistent/venus-debug/` 全部文件。
2. 在本机用 `journalctl -D` 与 `diff` 做完整对比，产出差异清单后再决定下一步。
3. 需要 grep 时说明取自完整日志的哪一段。

| 阶段 | 位置 |
|---|---|
| initrd（switch_root 之前） | `/persistent/venus-debug/initrd.log` |
| stage-2 之后 | `/persistent/var/log/journal`、`/persistent/venus-debug/journal.log` |
| 内核崩溃 | `/sys/fs/pstore` |

## 8. 诊断判据

- 结论必须落在日志原句上，给出文件与原句。
- "ping 不通"不是判据：区分不了内核崩、用户态没起、WiFi 没连。
- 固件 RDDM（`MHI_CB_EE_RDDM`）是固件自复位，与内核 oops 是两回事。
- 涉及版本/实现差异的结论必须给产物级证据（大小、md5、反编译、符号表），
  不能只凭名字或版本号推断。
- 同一结论至少两条独立证据。

## 9. 构建

- 优先 ml-builder 全速（客户端 `cores = 28`）；aarch64 原生打包步骤才派 opi5p，压到 4 jobs。
- 缓存只用 ncps；`builders-use-substitutions = false`。
- 构建失败先读完整 `nix log`，不做无诊断重试。
- 长构建主动报进度（在编什么、负载、剩余大件）。
- flake 源按 git 索引打包：新增文件必须 `git add` 才会进闭包（踩过：两次构建同一哈希）。

## 10. 内核 config 红线

- 不设 `CONFIG_INITRAMFS_SOURCE`：内嵌 initramfs 会建出真实 `/bin` 目录，遮住
  nixpkgs initrd 的 `/bin` 链接 → `initrd-find-nixos-closure` 报 `dirname: command not found`
  → `initrd.target` 依赖失败 → emergency。
- 改 config 后必须核对生成物里目标符号的实际取值。

## 11. 刷写红线

绝不 flash：`xbl*`、`xbl_config*`、`abl`、`tz`、`hyp`、`keymaster`、`devcfg`、`cmnlib*`、
`qupfw`、`imagefv`、`persist`、`modemst1/2` 与分区表。
可写：`boot_a/b`、`dtbo_a/b`、`vendor_boot_a/b`、`vbmeta_a/b`、`userdata`。

## 12. 代码与提交（留档是硬要求）

- 代码内不写注释，说明写提交信息。
- **每次实质改动（内核构建链、启动链、DTS、板级模块、工具）在当轮验证后必须立刻
  提交**，提交信息写明：改了什么、为什么、怎么验证的、证据在哪（日志目录/闭包/镜像 md5）。
  不允许把改动攒在工作区跨越多轮，也不允许只留在 `/tmp` 脚本里。
- 攻克一项能力时在 `docs/milestones.md` 记里程碑（定义 + 闭包/boot.img/DTB 的 md5 +
  日志位置 + 关键改动），里程碑之后不得回退该能力。
- **仓库里永远不得出现预编译内核产物**（`Image`、`*.dtb`、`modules/`、`modinst/`）。
  内核只能由 `nixos/kernel.nix` 从源码构建。历史上把手工编好的内核塞进仓库导致
  "冻结内核"与源码构建长期并存、结论互相打架；这条红线就是为了根除它。
  需要做 A/B 时，产物放在仓库外（如 `repro/`，已 gitignore），并在 `docs/experiments.md`
  记录它的来源与 md5。
- 提交与推送：提交可随时做；推送前说明会触发什么（`nixos-config` 的 master 推送会跑
  CI 的 dnscontrol，可能动线上 DNS）。部署仍需单独授权。
- 每轮设备实验结束后必须回写 `docs/experiments.md`；工具或规矩有变化同步更新本文件。
=======
- 本项目独立于 nixos-config 主仓,专门做小米11(venus)主线 Linux 适配,最终产出 NixOS
- **新 agent 接手先读 docs/HANDOFF.md（设备现状/已证事实/坑位清单）与 docs/porting-notes.md**
- 刷机红线:绝不 flash xbl*/xbl_config*/abl/tz/hyp/keymaster/devcfg/cmnlib*/qupfw/imagefv/persist/modemst1/2 与分区表
- **venus 的 ABL 不支持 `fastboot boot` 内存引导(静默不执行)**:日常验证只能写 `boot_b`/`boot_a` 后 `reboot`
- 刷机操作走 Windows 主机(`ssh molis@192.168.0.143`,platform-tools 在 `C:\Users\molis\mi11\platform-tools`);
  本机 fastboot 大传输会断。**每次让用户操作前先声明需要的手机状态**
- ROM 包与官方镜像常备 `~/mi11-work/`,官方恢复路径见 porting-notes(EvoX First Time Install)
- 厂商固件文件不进 git(`nixos/firmware/` 已 gitignore),从 modem/vendor 分区提取
- **内核产物不进 git**(`nixos/kernel/` 已 gitignore):内核只能由源码 + `tools/apply-kernel-patches.sh` 重建
- 提交用 conventional commits,中文说明原因,并写清「改了什么/为什么/怎么验证的/证据在哪」

## 当前状态（2026-11-15，已实测 2/2 冷启动）

设备：新机 12GB 内存（旧机 8GB 已随第一次项目终止报废）。槽位：a=Android(EvoX)，b=NixOS。

跑通并通过验收的能力：

| 能力 | 证据 |
|---|---|
| WiFi（WCN6851, WiFi6） | `wlan0` 自动关联 `moli-1004-backup` → 192.168.0.150；`iw dev wlan0 link` 报 2401.9 MBit/s 160MHz HE-MCS11 NSS2；root SSH 可用 |
| USB ACM 串口 | `/sys/class/udc/a600000.usb/state=configured`；Windows 侧 `VID_18D1&PID_4EE1` 的 COM3 |
| 桌面/触摸/GPU | Plasma 起得来，面板与触摸驱动在 `kernel/venus/` |
| 系统健康 | `systemctl --failed` 为空，`MHI_CB_EE_RDDM` 计数 0，`free -h` 报 10Gi 可用 |

## 三条硬前提（缺一条 WiFi 就死）

1. **内核必须有 `userspace-consumer` 补丁**。缺它时五路 WiFi regulator probe 报
   `reg-userspace-consumer regulator-wifi_aon: error -EBUSY: Failed to get supply 'vout'`
   与 `probe with driver reg-userspace-consumer failed with error -16`，于是
   `/sys/bus/platform/devices/regulator-wifi_*/state` 不存在，`venus-wifi-power` 的
   `echo enabled` 全部落空，PCIe 永远停在 `qcom-pcie: Device not found`，ath11k 一行日志都没有。
2. **WCN6851(hw1.1) 的 `.num_vdevs` 必须是 3**（不能照抄 WCN6855 hw2.0 的 4）。
   4 时固件自复位：`firmware crashed: MHI_CB_EE_RDDM` + `failed to receive wmi unified ready event: -110`。
   依据是上游 `[PATCH v2 2/7] wifi: ath11k: enable support for WCN6851` 作者原话
   “This crashes with the firmware that came with the board … I will revert to 3 vdevs for v3”
   与 SM8350 用户复现。`tools/apply-kernel-patches.sh` 第 8 段负责这一处（幂等）。
3. **`dtbo_b` 必须写零**（24MB 全零镜像）。只要 dtbo 槽里有 overlay，ABL 就用 dtbo 的 DTB，
   自建 DTB 完全不生效——症状是显示正常但 USB 串口与 WiFi 同时不在。

## 基线原则

- 代码基线 = 10-25 的 `86d6b46`（NixOS 25.05 跑通那版）。**唯一允许的偏离是 DTS 的内存布局**
  （12GB 机型）：`memory {}` 占位交给 ABL 注入、`removed_mem` 0xa000000、
  `cont_splash`/`framebuffer` 0xea600000、`dfps_data_mem` @0xec900000、
  `xbl_aop_mem` 0x80600000+0x260000。
- nixpkgs 必须 pin 在 `nixos-25.05`：26.11 求值 10-25 配置直接失败
  （`boot.kernelPackages.kernel.buildDTBs` 缺失、`services.logind/journald.extraConfig` 已移除）。
- `nixos/configuration.nix` 里的 WiFi `psk` 只提交占位符，明文留在工作区。

## 构建与部署

```sh
# 1) 内核（交叉编译，host 侧，非仿真）
nix develop -c bash -c 'make -C $HOME/.cache/venus-k27/src O=$HOME/.cache/venus-k27/build \
  ARCH=arm64 CROSS_COMPILE=aarch64-unknown-linux-gnu- -j12 Image dtbs'
#    源码树先要打过补丁：
KSRC=$HOME/.cache/venus-k27/src tools/apply-kernel-patches.sh
# 2) boot.img（内核 + DTB + NixOS initrd + 注入 preinit，cmdline 用 init=/nix/var/nix/profiles/system/init）
tools/make-bootimg.sh /tmp/venus.img
# 3) 刷：boot_b 用 fastboot，rootfs 走 `nix copy --to local?root=…` + img2simg 的 userdata 镜像
```

- initrd 用 NixOS 官方脚本式 initrd（**不要**迁 systemd-initrd：10-27 已因此半启动一次）
- 内核红线：不设 `CONFIG_INITRAMFS_SOURCE`（内嵌 initramfs 会遮住 nixpkgs 的 `/bin`），
  改 config 后必须核对生成物里目标符号的实际取值

## 日志与取证

- 现在是**双通道**：WiFi SSH（`root@192.168.0.150`）+ USB ACM 串口（Windows COM3）。
  串口在 initrd 与 stage-2 都活着；`tools/serial.sh` 走本机 ACM，Windows 侧用
  `tools/wserial.sh` 或直接 PowerShell 打开 COM3。
- 失败时取完整日志：`journalctl -b`、`/persistent/venus-debug/`、`/sys/fs/pstore`；
  **不要只 grep 几行就下结论**。
- 结论必须落在日志原句上，同一结论至少两条独立证据；推断（无验证命令）只能当假设。

## 实验纪律

- 一轮只改一个变量，六件套（kernel/dtb/initrd/init=/profile/cmdline）md5 全部登记
- 判据事先写死；拿不到日志的轮次标为“无效实验”，不得据此下结论
- 每轮结束后回写 `docs/porting-notes.md`，工具或规矩有变化同步更新本文件
>>>>>>> main
