# 交接文档（写给下一个接手的 agent）

> 最后更新: 2026-10-24 深夜。前任 agent 调试了一整天的状态全部在此。
> 先读完本文档和 docs/porting-notes.md 再动手。手机状态每次操作前必须与用户确认。
>
> ⚠️ **可信度警告**: 前任 agent 在本次调试中产出过多个后来被证伪的结论(电池论/尺寸论/header论/QMP论/BCB论),
> 均已记录在 docs/porting-notes.md「误判记录」。本文档已按置信度分级标注,
> 但**铁律是: 任何叙述都可用一条命令重新验证(验证命令已附), 验证优先于信任叙述**。
> 对无验证命令支撑的推断(标 🔶), 当作假设而非事实。

## 最新状态（2026-10-26 晚间更新，覆盖下面旧叙述）

设备跑 **NixOS 25.05**（自建内核 7.2.6），从 boot_b 引导。

**已实测可用**：UFS / USB 串口 / WiFi（开机自连 <LAN_PHONE_IP>，`ssh venus`）/ GPU（Adreno 660，
turnip+freedreno，glmark2 413@1440x3200）/ **面板显示（含刷新）** / 背光（正向映射，默认 128）/
**KDE Plasma 6 桌面（SDDM 免登录）** / 三颗按键。

**屏幕刷新问题已解决**：根因是 `sm8350.dtsi` 的 mdss 没有 `vsync` 时钟 →
`dpu_encoder_phys_cmd_tearcheck_config()` 拿不到频率直接 return → tearcheck 不使能 →
命令模式面板只有 modeset 首帧。修法是取不到时用 19.2MHz 兜底（改在
`drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_cmd.c`）。**部署时必须核对 build-id**，
别把旧模块当成新的（我差点误判）。

**触屏已通（2026-10-26 深夜）**：`kernel/venus/fts-spi-venus.c` + DTS 的 `spi11/touchscreen@0`
+ `ts_avdd`（GPIO132）。开机由 `venus-touch.service` 依次加载 `spi-geni-qcom` 与 `fts-spi-venus`。
关键点：厂商 Sense ON 是 `setScanMode(ACTIVE, 0x01)`（0x00 不产事件）；上电时复位必须保持有效；
SPI 下读事件第 0 字节是 dummy；事件格式 `id=(e1&0xF0)>>4, x=((e3&0x0F)<<8)|e2, y=(e4<<4)|((e3&0xF0)>>4)`。
响应优化：一次事务读回整条 FIFO（256B）再解析。详见 docs/porting-notes.md。

**仍未通**：充电/电池（上游无驱动）。蓝牙（hci0 注册但不回 HCI 命令，留档待续）。

**操作纪律（血泪，照做）**：
- 重启只用 `echo b > /proc/sysrq-trigger`（`systemctl reboot` 在这台机器上不生效）。
- 测 DRM 设备权限只能用 `open()`，**绝不要 `read()`**：`dd if=/dev/dri/card1` 会永久阻塞并占住设备，
  之后 KWin 会报 `Device or resource busy`、Plasma 起不来。
- 仓库 HEAD 的 DTS 里有**实验性且会挂机**的改动（`te-source = "mdp_intf0"`、给 mdss 加 `vsync` 时钟），
  设备上跑的是更早那份 `te-source = "mdp_vsync_e"`。重打 DTB 前必须先把这两处退回。
- `git tag screen-ok-v101` 指向的提交含上述实验性改动与触屏代码，**不能当回滚点**。
- 已知良好镜像：`~/mi11-work/known-good/boot-screen-ok-v101.img`；
  模块包：`/root/ko/`（`msm.ko` 已换成带兜底补丁的版本，`msm-old.ko` 可回退）。

## 〇、置信度分级说明

- ✅ = 直接多次观测/带验证命令, 可直接采信(但仍建议首次使用时重新验证)
- 🔶 = 推断或单次观测, 使用前必须自行重新验证
- ❌ = 前任的错误结论, 已被证伪, 列出仅供避免重蹈

## 一、当前设备状态（已验证）

- 小米 11 (venus, SM8350)，bootloader 已解锁（解锁 + critical 解锁）
- **slot a = 健康的 EvolutionX 12.3**（boot_a/dtbo_a/vendor_boot_a/vbmeta_a 全部官方原版，2026-10-23 官方 OTA 全量重装过），adb 已授权（密钥在 Windows 侧，插线即可用）
- **slot b = EvoX 官方**（boot_ab/dtbo_ab/vendor_boot_ab 双槽刷过）
- misc = 全零（干净）；userdata = 空的（重装时 Format data 过）
- 注意: a/b 槽的 try-counter 会被失败的引导烧光，烧光后该槽 `Load Error`；`fastboot set_active <slot>` 重置。当前 a 槽标志健康

## 二、手机现在的引导资产

- boot_a = **EvoX 官方 boot.img**（能正常开机进系统）✅ 验证: `fastboot getvar current-slot` + EvoX 能启动
- vendor_boot_a = **EvoX 官方 vendor_boot**（含小米完整 DTB 7.9MB + EvoX ramdisk）✅ 同上
- 我们的内核在 `~/mi11-work/images/venus-boot-v15.img`（header v3，11.8MB，内嵌 initramfs）
  🔶 注意: v15 镜像里的 initramfs 是否真的包含修复后的 init(busybox --install), 构建时序上应该包含但未端到端验证——misc 读出的日志会直接回答(init 是否能跑 dd/mount)

## 三、已确证的事实（✅=直接多次观测 / 🔶=推断待验）

1. ✅ **venus 的 ABL 不支持 `fastboot boot`（内存引导）**：v2/v3/v4 三种 header 均静默不执行。验证: 任一次 `fastboot boot X.img` rc=0 但无任何后续。
2. ✅ **主线内核 7.2.6 能启动到 initramfs 用户态**：v12 用 45s 时间信标精确回 fastboot 验证(74s 总耗时=引导+信标)。
3. 🔶 **主线内核下 USB UDC 从未出现过**：从未在手机内部直接观测过(没有日志通道), 仅由「Windows 无 NCM 网卡」推断。**misc 日志(第四节)读出后此条升级为实证或被推翻。**
4. ✅ **PMIC 硬件看门狗存在且 ~32s 超时**: pdx206 文档记载 + 我们 v12 的 74s 回 fastboot 与之兼容(也可能是 beacon, 二者在本轮实验中不可区分, 但喂狗无害)。
5. ✅ **v13+ 的 init 会把 dmesg 写进 misc 偏移 4KB 起**: 代码在 kernel/venus/initramfs/init 里可见; 但**写入是否成功从未被读取验证过**(rd12 的输出用户未转述即丢失)。rd14 读取就是验证本身。
6. 🔶 **`busybox --install -s /bin` 缺失**导致 applet 全不存在: initramfs 只有 busybox+sh 两个文件是 ✅ 直接验证过的; 但「因此 mount/dd 全部失败」是推断(未在手机上直接观测过报错)。
7. ❌ **已被证伪、勿再采信的旧结论**(详见 porting-notes 误判记录):
   - 电池/电量问题(用户从未拆机, 满电)
   - "下载尺寸超限"是真实尺寸问题(实为断连假错误, 192MB flash 实测可行)
   - header 版本导致 Load Error(v3/v15 同为 v3 header, 一个成功一个循环)
   - QMP PHY 内建本身导致 panic(v11 QMP=m 仍循环)
   - BCB boot-recovery 能让小米 ABL 自动进 sideload(实测直落 fastboot)
   - "v12 的 74s 回 fastboot = 我们的时间信标"(也可能是看门狗, 见第 4 条)

## 四、🔴 第一优先任务：读取 v15 的 misc 日志

v15 引导存活 ~90s，init 每 15 秒把 dmesg 写进 **misc 分区偏移 4KB 起**（`/dev/block/by-name/misc`，BCB 在 0-4KB 别动）。日志里有 UDC/dwc3/qusb2 的探测现场 = 下一步的唯一依据。

读取流程（rd14 已推到 Windows `C:\Users\<windows-user>\mi11\ramdump14.zip`）：
1. 用户把手机弄进 fastboot（电源+音量下 15s）
2. `fastboot flash boot_a venus-boot-v15.img`（misc 不动）
3. `fastboot set_active a && fastboot continue`（新鲜会话单发，见纪律）
4. 黑屏挂 60-90s（写日志）→ 用户电源+音量下 → fastboot
5. `fastboot flash boot_a boot.img`（EvoX）→ `fastboot reboot recovery`
6. 用户: Apply update → Apply from ADB → 说「好了」
7. `adb sideload ramdump14.zip` → **用户读屏幕 ~15 行**（venus lines / block / udc / dwc3 / qusb2）→ 把文字转给分析

注意: sideload 的 ui_print **不会**回流 adb stdout（现代 adb），只能屏幕读。每次 sideload 后 adb 自动退出回主菜单。

## 五、关键坑位清单（全部踩过，血泪）

- **fastboot continue 只在新鲜 fastboot 会话里可靠**：同会话第二次起几乎必 `Load Error`。每次引导实验 = 用户重进 fastboot → 单发。
- **NixOS 侧 fastboot 大传输必断**（报 max allowed 假错误）：刷机一律走 Windows（ssh <windows-user>@<LAN_WINDOWS_IP>，密码 <WINDOWS_SSH_PASSWORD>，工具在 C:\Users\<windows-user>\mi11\platform-tools\）。
- **Windows 侧 VMware 会抢 USB 总线**：手机从设备列表消失时先让用户重插，别怀疑手机。
- **Windows adb server 时机病**：模式切换（fastboot↔adb↔sideload）后必须 `adb kill-server` + 重启再扫，否则看不到设备。
- **Recovery 主菜单 adb 是关的**，只有手动进 Apply from ADB 才有；sideload 完成后自动回主菜单（adb 又关了）。
- **Recovery 无 /dev/mem、/sys/class/block 被锁、/proc/partitions 为空**；读块设备只能 `/dev/block/bootdevice/by-name/*`（rd7 实证 resolved=/dev/block/sda34）。
- **recovery 和系统都会挂 /data**（F2FS 重放），写 userdata 尾部存的日志会被吃掉——所以用 misc。
- **EvoX recovery 的 ui_print 不回流 adb stdout**，只能屏幕读（现代 adb 行为）。
- getvar max-download-size 报 768MB 但实际不可信；传输断连时报 "Requested download size is more than max allowed" 假错误。
- 自创的 BCB boot-recovery 自动进 sideload：**小米 ABL 不理**（misc 写 boot-recovery 后 reboot 直落 fastboot）。别再试。

## 六、下一步路线（读完成 misc 日志之后）

1. 从 dmesg 定位 UDC 不出现/panic 的真因，修 init 或内核配置 → v16
   - 参考命令行参数依据: pdx206 Phase 4 (regulator_ignore_unused pd_ignore_unused clk_ignore_unused), 对 venus 未单独验证过有效性, 但加上了无害
2. M1 验收: Windows 出现 NCM 网卡 → `ip addr add 10.15.0.1/24` → `telnet 10.15.0.2`（init 里有 telnetd）→ shell
3. M2: UFS 实测（init 已有探测代码）
4. M3: NixOS rootfs（参考 chayleaf OnePlus 6 博客 + pmOS sm8250 kernel 包）
5. 终点: SteamOS 栈（gamescope + Steam ARM64 + FEX + Turnip[Adreno 660 已支持]），屏幕暂不适配
6. 参考: mainlining.dev（Iskren Chernev 的 mainline 移植指南）、pdx206-mainline、Fairphone4 FOSDEM 2023 幻灯（首启 40 行 dts 即通 USB）

## 七、基础设施

- 构建环境: 本仓 `nix develop`（交叉工具链在内），产物打头部 v3 boot
- 内核源: `~/.cache/venus-kernel/linux-7.2.6`（makefile 已注 venus dts），构建目录 `~/.cache/venus-kernel/linux-build`
- initramfs 源: `kernel/venus/initramfs/`（INITRAMFS_SOURCE 内嵌进 Image）
- 本机镜像服务: `systemctl --user status mi11-http`（:8000 → ~/mi11-work/images/）
- Windows 拉取: `curl.exe -s -o <file> http://<LAN_HOST_IP>:8000/<file>`
- 备份/镜像资产: `~/mi11-work/`（evox-17/ 官方镜像 + images/ 全部自编版本 + evox-rom.zip 3.7GB 官方 OTA）
- 官方救砖路径（已验证）: EvoX First Time Install = flash boot_ab/dtbo_ab/vendor_boot_ab + Format data + adb sideload rom.zip，见 docs/porting-notes.md 2026-10-23 节
