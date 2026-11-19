# venus-mainline 约定

小米 11（venus / SM8350）的 standalone NixOS。目标是系统跑通、WiFi 可用、串口可用，
日志里不留异常。fleet 角色在本机 standalone 清零前不碰。

## 当前状态（2026-11-19，里程碑 M3：fleet 文件系统布局 + WiFi + 串口）

**系统是 NixOS 26.11，rootfs 改成 fleet 同款布局**（`/` = tmpfs，`/nix` = btrfs label
`NIXOS_NIX`、`compress-force=zstd`），`/nix` 已扩到整块 224G。闭包
`ikdxzx04p70z5sk8klp6yb5mqpn6ar78`，boot.img md5 `c04066f955ab02872b471386f451d438`
（= `/nix/persistent/boot-milestone.img`，deadman 的回滚目标；`.closure` 同目录）。

2026-11-19 冷启动实测（日志 `~/venus-logs/20261119-1600/`，设备侧
`/nix/persistent/venus-debug/journal-b.log`）：

| 能力 | 实测 |
|---|---|
| 文件系统 | `/` tmpfs `size=80%,mode=755`；`/nix` btrfs `compress-force=zstd:3,autodefrag`，225G 可用 221G |
| WiFi（WCN6851） | `wlan0 UP 192.168.0.68/24`；SSID `moli-1004-backup` **freq 5300（ch60）**；2401.9 MBit/s / 160MHz / HE-MCS11 / NSS2；signal -31 dBm；fw `0x11008104`；`MHI_CB_EE_RDDM` = 0 |
| 系统 | `systemctl --failed` = 0；`/run/current-system` = `/run/booted-system` = `ikdxzx04…` |
| USB 串口 | stage-2 也活着：`/sys/class/udc/*/state` = `configured`、`/dev/ttyGS0` 存在、Windows `COM3` 可用 |
| PCIe | dmesg 里 `qcom-pcie` 17 行 |

**两条调试通道**：WiFi SSH `root@192.168.0.68`（主）+ 串口 `tools/serial.sh`（备用，root shell 需
在 ttyGS0 上输密码；`venus` 用户可无密码 sudo）。

部署已不需要 fastboot：`nix copy --to ssh://root@192.168.0.68 <closure>` →
`dd if=<boot.img> of=/dev/disk/by-partlabel/boot_b bs=1M conv=fsync`（读回校验 md5）→
`nix-env -p /nix/var/nix/profiles/system --set <closure>` → `reboot`。deadman 回滚用的也是这条 dd。

容易重踩的坑（前四条 11-18 记，后四条 11-19 记）：

1. `systemd-networkd` **每个 link 只用一个 `.network` 文件**（按文件名取第一个匹配）。
   把 MAC 放 `10-wlan0`、IPv4 放 `20-wlan0` 时只会应用前者 → 只有 IPv6、没有 IPv4 → 看起来
   "WiFi 没通"，实际 wpa_supplicant 早已关联成功。MAC 与地址必须写在同一个文件里。
2. `venus.debug.enable = true` 会往 cmdline 注入 `rd.debug` / `loglevel=8` / `oops=panic` /
   `panic=30`，在唯一 115200 串口上等于把启动拖成分钟级，且任何 oops 变致命。
3. systemd 的 unit-script 带 `set -e`：`x=$(... | grep -c ...)` 在零匹配时会让整个脚本立刻退出；
   且 `ip -4 -br addr` 的**简要输出不含 "inet" 字样**（形如 `wlan0 UP 192.168.0.68/24`），
   用它 grep 'inet ' 恒为 0 —— 曾让 deadman 把"WiFi 明明通着"误判成无网。
4. `moli-1004-backup` 在 AP 上有两个 BSSID（`…:d5` 可用、`…:d4` 认证不过），所以钉死
   `bssid=…:d5` 是对的。**但不要钉 `scan_freq`**：2026-11-19 AP 从 ch36(5180) 换到 ch60(5300)，
   `scan_freq=5180` 让 wpa_supplicant 永远扫不到该 BSS（症状：`wlan0 DOWN`、`Not connected`）。
5. **boot.img 只能由 `tools/boot-img.sh` 生成**。手拼 mkbootimg 命令行漏掉 `root=fstab` 时，
   systemd-initrd 拿不到 root 描述 → `/`(tmpfs) 与 `/nix`(btrfs) 的 sysroot 挂载单元都不会生成 →
   `initrd-find-nixos-closure` 失败 → `initrd.target` 的 `OnFailure=emergency.target`
   (`replace-irreversibly`) 把 `venus-serial.service` 一起取消 → **既没网也没串口，零日志**。
   2026-11-19 实证：同闭包同 DTB，仅 cmdline 有无 `root=fstab` 之差，一死一活。
6. WiFi `psk` 会与 AP 实际密码不一致（11-19 时仓库里是 25 字符的旧值，4-way handshake 报
   `WRONG_KEY`）。以一台能连上的机器上 NetworkManager 的 psk 为准，别凭记忆。
7. `/persistent` 已全部改成 `/nix/persistent`（fleet 约定）。tmpfs 根上写 `/persistent`
   等于写内存，重启即失——取证、deadman 计数、里程碑镜像都必须落 `/nix/persistent`。
8. `venus-grow-nix` 必须用 `btrfs filesystem resize max /nix`；原来写 `resize2fs` 对 btrfs 无效，
   镜像永远停在 8G。

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
| 经 Windows COM 口给设备发命令（`MI11_WAIT=秒` 可等端口枚举） | `tools/serial.sh "<命令>" [秒]` / `--read` |
| 从闭包做 btrfs userdata 镜像（sparse，可直接 flash） | `tools/mkbtrfs-img.sh <closure> <out.simg> [--hostkey <file>]` |

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
| `venus`（ssh 22） | 里程碑 M2：26.11 + WiFi 可用 | 可 SSH，走第 3 节 |
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
可写：`boot_b`、`dtbo_b`、`userdata`。（`boot_a`/`dtbo_a` 不再使用，见"单槽单系统"）

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
## 13. 历史遗留事实（旧文档里仍然有效的部分）

- 设备是新机 **12GB 内存**（旧 8GB 机已报废）。槽位 a=Android(EvoX)、b=NixOS，本项目只用 b。
- 本项目独立于 `nixos-config` 主仓；`nixos-config` 里 `hosts/venus` 与 fleet 配置一行不改。
- 刷机红线同上（见第 11 节）。ROM 包与官方镜像常备 `~/mi11-work/`。
- **venus 的 ABL 不支持 `fastboot boot` 内存引导**（静默不执行）：验证只能写 `boot_b` 后 `reboot`。
- **三条硬前提，缺一条 WiFi 就死**：
  1. 内核必须有 `userspace-consumer` 补丁（`tools/apply-kernel-patches.sh`）。缺它时五路 WiFi
     regulator probe 报 `reg-userspace-consumer regulator-wifi_aon: error -EBUSY: Failed to get
     supply 'vout'`，`/sys/bus/platform/devices/regulator-wifi_*/state` 不存在，
     `venus-wifi-power` 的 `echo enabled` 全部落空，PCIe 永远 `Device not found`。
  2. WCN6851(hw1.1) 的 `.num_vdevs` 必须是 **3**（不是 hw2.0 的 4），否则固件自复位
     `firmware crashed: MHI_CB_EE_RDDM` + `failed to receive wmi unified ready event: -110`。
  3. `dtbo_b` 必须写零（24MB 全零镜像），否则 ABL 用 dtbo 的 DTB，自建 DTB 完全不生效。
- DTS 里"为硬件而改"的只有内存布局（12GB 机型）：`memory {}` 交给 ABL 注入、`removed_mem`
  0xa000000、`cont_splash`/`framebuffer` 0xea600000、`dfps_data_mem` @0xec900000、
  `xbl_aop_mem` 0x80600000+0x260000。
- 厂商固件默认不进 git；唯一例外 `nixos/firmware/ath11k/WCN6855/hw1.1/`（4MB，上游
  linux-firmware 只有 hw2.0/hw2.1）。内核产物一律不进 git。
- `nixos/configuration.nix` 的 WiFi `psk` 只提交占位符，明文留在工作区。
- 内核红线：不设 `CONFIG_INITRAMFS_SOURCE`（内嵌 initramfs 会遮住 nixpkgs 的 `/bin`）。
