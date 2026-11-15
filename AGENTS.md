# venus-mainline 项目约定

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
