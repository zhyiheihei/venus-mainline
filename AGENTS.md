# venus-mainline 约定

小米 11（venus / SM8350）的 standalone NixOS。目标是系统跑通、WiFi 可用、串口可用，
日志里不留异常。fleet 角色在本机 standalone 清零前不碰。

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

## 12. 代码与提交

- 代码内不写注释，说明写提交信息。
- 提交、推送、部署分别需要单独授权。
- 每轮设备实验结束后必须回写 `docs/experiments.md`；工具或规矩有变化同步更新本文件。
