# 交接文档（写给下一个接手的 agent）

> 最后更新: 2026-10-24 深夜。前任 agent 调试了一整天的状态全部在此。
> 先读完本文档和 docs/porting-notes.md 再动手。手机状态每次操作前必须与用户确认。

## 一、当前设备状态（已验证）

- 小米 11 (venus, SM8350)，bootloader 已解锁（解锁 + critical 解锁）
- **slot a = 健康的 EvolutionX 12.3**（boot_a/dtbo_a/vendor_boot_a/vbmeta_a 全部官方原版，2026-10-23 官方 OTA 全量重装过），adb 已授权（密钥在 Windows 侧，插线即可用）
- **slot b = EvoX 官方**（boot_ab/dtbo_ab/vendor_boot_ab 双槽刷过）
- misc = 全零（干净）；userdata = 空的（重装时 Format data 过）
- 注意: a/b 槽的 try-counter 会被失败的引导烧光，烧光后该槽 `Load Error`；`fastboot set_active <slot>` 重置。当前 a 槽标志健康

## 二、手机现在的引导资产

- boot_a = **EvoX 官方 boot.img**（能正常开机进系统）
- vendor_boot_a = **EvoX 官方 vendor_boot**（含小米完整 DTB 7.9MB + EvoX ramdisk）
- 我们的内核在 `~/mi11-work/images/venus-boot-v15.img`（header v3，11.8MB，内嵌 initramfs）

## 三、已确证的事实（每条都有实证，勿再怀疑）

1. **venus 的 ABL 不支持 `fastboot boot`（内存引导）**：收镜像后静默不执行，header v2/v3/v4 都一样。只能 `flash + set_active + continue`。
2. **主线内核 7.2.6 能在 venus 启动到 initramfs 用户态**：v3/v12 两次实证（v12 用 45s 时间信标精确回 fastboot 验证）。
3. **主线内核下 USB UDC 从未出现过**：v3→v15 全部如此。v15 已修 `busybox --install`（见下），仍 ~90s panic 循环——**真正死因在 v15 的 misc 日志里，尚未读取**。
4. **历史误诊已排除**：不是电池、不是 header 版本、不是下载大小、不是 QMP PHY 内建本身（v11 QMP=m 仍循环）。
5. **真正的历史根因之一（已修）**：init 缺 `busybox --install -s /bin`，导致 mount/dd/ip/telnetd/reboot 全部不存在 → configfs 从未挂载、日志从未落盘。来源: pdx206-mainline 项目（github.com/terminal-index/pdx206-mainline，同 SoC 成功移植，必读）。
6. **PD 三个 cmdline 参数必须加**（pdx206 Phase 4）：`regulator_ignore_unused pd_ignore_unused clk_ignore_unused`——否则 ~30s 时 regulator_late_cleanup 关掉未认领电源轨（含 USB PHY 供电）→ 无 panic 死机。v15 已加。
7. **PMIC 硬件看门狗**：XBL 启动即开 ~32s 倒计时，没人喂就无 panic 硬复位。修: `CONFIG_QCOM_WDT=y`（v14 起）+ init 里 `busybox watchdog -t 5 /dev/watchdog &` 兜底。v15 已加。

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
