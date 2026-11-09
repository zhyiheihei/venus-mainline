# venus-mainline v0.1.0

发布日：2026-11-09。首个"日常可用"版本：小米 11（venus / SM8350，12+256）跑 NixOS 25.05，
桌面、触摸、GPU、WiFi、蓝牙、电池充电全部可用，SSH 与串口两条通道都在。

## 设备上运行的到底是什么（可复现的标识）

| 项 | 值 |
|---|---|
| 内核 | `7.2.6` / `#52 SMP PREEMPT Wed Oct 28 09:24:26 CST 2026` |
| 内核 Image md5 | `b08a5eb2628eb8ff6c1cdf0b2eca84ca`（43,325,952 字节） |
| 系统闭包 | `9nv5kxlxzalswnhybszpmxxvg7dgm31g-nixos-system-venus-25.05.20260102.ac62194` |
| boot_b 内容 md5 | `dd488b8eefcc2f8567459f8e37e2b2c1`（201,326,592 字节） |
| 仓库 commit | 本 tag 指向的提交 |
| 分区 | slot b = boot_b / dtbo_b（写零）/ userdata（12GiB ext4，LABEL=nixos） |
| 启动参数 | `firmware_class.path=/venus-fw console=tty0 console=ttyGS0,115200 init=/nix/var/nix/profiles/system/init net.ifnames=0 loglevel=7 regulator_ignore_unused pd_ignore_unused clk_ignore_unused` |

## v0.1.0 覆盖的硬件

可用：启动（ABL 注入内存）、显示（DSI 命令模式 + K2 AMOLED 1440x3200）、背光、触摸（ST FTS SPI）、
GPU（freedreno/turnip，glmark2-es2-wayland = 904）、UFS、WiFi（WCN6851/ath11k，5300MHz/-14dBm，
50 包 0% loss）、蓝牙（hci0 UP，扫描正常）、电池与充电（qcom_battmgr，PD/SDP/DCP 枚举）、
温度（41 个 zone）、CPU 调频、电源键与音量上键、USB 设备模式（ACM 串口控制台）。

明确不在范围内：音频（CS35L41 已黑名单，其 IRQ 风暴会让整机卡死）、红外发射（驱动就绪但
内核改动会连带 WiFi 失效，主动放弃）、摄像头、基带、运动/光距传感器、振动、NFC、休眠（会复位）、
USB OTG 接键鼠（DTS/配置已就绪但依赖重建内核）。

逐项状态与依据见 `docs/hardware-status.md`；配置审核见 `docs/audit-sm8350.md`。

## 这一版解决掉的三类根因

1. **卡米标**：DTS 的 `memory` 写死了旧 8GB 机布局。改为全零占位由 ABL 注入；
   另按手机真实 DT 修正 9 处 reserved-memory。
2. **WiFi 起不来 / 连上又掉**：rootfs 的 `/nix/store` 属主不是 root:root（NetworkManager 跳过
   wifi 插件）；ath11k 省电导致掉包；声明式 profile 缺 uuid 导致出现两条同名连接互抢 wlan0。
3. **触摸失效 + 整机卡死**：CS35L41 功放 IRQ 风暴（`irq 210: nobody cared`），黑名单后消失。

## 已知差异与遗留（都写进文档了）

- 设备本次运行的 DTB 是 20:44 那份（含 pinctrl 修复前的版本）；仓库里的 DTS 已经包含
  `wlan_en`/`bt_en` 的 pinctrl（`pin 64: device regulator-wlan-en function gpio` 已验证）。
  这条差异不影响当前可用性，计划在 v0.1.1 随下一次刷机合并。
- **重建内核不可用**：这台机的 WiFi 是 WCN6851(hw1.1)，主线只认 hw2.0/2.1；
  最小补丁已写进 `tools/apply-kernel-patches.sh`，但该内核死在 early boot（无 journal、无 pstore）。
  要往前推进必须有串口——手机 USB 口目前在 Windows（PVE 直通）与本机都不枚举，属物理层问题。

## 复现方式

```bash
# 配置部署（不刷镜像）
tools/install-venus.sh deploy

# 从零装机（需要 fastboot + Windows 刷机机）
tools/install-venus.sh dtb && tools/install-venus.sh bootimg \
  && tools/install-venus.sh rootfs && tools/install-venus.sh flash
```

构建前务必：

```bash
export NIX_CONFIG="substituters = http://192.168.0.56:13851 https://cache.nixos.org"
# 本机 / 与 /tmp 是 tmpfs，别把 12GiB 镜像写到那里（会整机 OOM）
```

## 回滚

设备内保留 `/root/boot_b-good.img`（与本版 boot_b 同内容），无网络也能就地恢复：

```bash
ssh root@<phone> 'dd if=/root/boot_b-good.img of=/dev/sde38 bs=1M conv=fsync && reboot'
```

`venus-wifi-fallback` 服务会在开机 90s 无 WiFi 时自动做同样的事（≤5 次），
并把现场写进 `/var/log/venus-bootfail.log`。
