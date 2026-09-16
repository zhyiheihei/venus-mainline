# venus-mainline

小米11(venus,SM8350/骁龙888)主线 Linux / NixOS 适配项目。

## 目标

在无硬件串口、无 9008(EDL)救砖的条件下,以 `fastboot boot` 内存引导为安全兜底,把 mainline Linux 跑上 venus。最终形态:

1. headless NixOS:USB gadget 网络 + SSH,可用作小盒子
2. 逐项点亮外设:WiFi → 屏幕 → 蜂窝/音频(远期)

## 现状评估结论(2026-09 定稿)

| 层 | 状态 |
| --- | --- |
| SM8350 平台 | UFS/USB/CPU 调频/PCIe/DSI/GPU/remoteproc 已进主线;WiFi/BT 板级 2026-06 刚给 HDK 打补丁;音频/摄像头/视频硬解/GPS 空白 |
| venus 设备 | 主线无 DTS;pmOS 标记 not booting(卡在 1440p DSC 面板 bpp=30);USB 与 regulator 已通 |
| NixOS 侧 | Mobile NixOS 无 sm8350;走「自建内核 + 标准 NixOS rootfs」路线(参考 Vanilla Mobile NixOS 与 chayleaf 的 OnePlus 6 博客) |
| 先行参考 | Sony Xperia 1 III(pdx215,同平台):pmOS 有 mainline port,USB 网络/屏幕/GPU 通,WiFi/蜂窝全空,跑 SD 卡(UFS 被禁)。venus 无 SD 卡槽,必须啃 UFS |

## 路线图

| 里程碑 | 内容 | 验收 |
| --- | --- | --- |
| M0 | 备份原厂 boot/dtbo/vbmeta/vendor_boot;备 LOS 完整 fastboot 包 | backup/ 下分区镜像齐全(不入 git) |
| M1 | mainline 内核 + sagami DTS 起步改造,`fastboot boot` 引导 | initramfs 里 USB 网络可用,可进 debug shell |
| M2 | UFS 实测:只读确认分区、检查稳定性 | 决定落盘策略(boot_b + userdata) |
| M3 | NixOS rootfs + USB NCM + SSH | headless 可用,`nixos-rebuild` 闭环 |
| M4 | USB 转以太网网卡 | 独立联网保底 |
| M5 | WiFi:等 sm8350-hdk WiFi 补丁进主线,写 venus 供电/PCIe DTS,从 LOS 固件包提取 boardfile | wpa_supplicant 关联成功 |
| M6 | 面板(1440p DSC bpp=30,独立战线,最大硬骨头) | 亮屏 |

蜂窝/音频/摄像头列为远期,不进当前路线图。

## 红线(守住则永远不需要 9008)

绝不 flash:`xbl*`、`xbl_config*`、`abl`、`tz`、`hyp`、`keymaster`、`devcfg`、`cmnlib*`、`qupfw`、`imagefv`、GPT 分区表。

可折腾:`boot_a/b`、`dtbo_a/b`、`vendor_boot_a/b`、`vbmeta_a/b`(带 `--disable-verity --disable-verification`)、`userdata`。

日常测试用 `fastboot boot boot.img`(内存引导,零永久风险),验证通过才落盘 `boot_b`,`boot_a` 常留安卓。

## 目录

| 路径 | 说明 |
| --- | --- |
| `hosts/venus/` | NixOS aarch64 headless 配置 |
| `kernel/` | mainline 内核构建(patch 集与 config,M1 落地) |
| `firmware/` | 固件提取说明(M5 落地) |
| `docs/porting-notes.md` | 移植日志 |
| `backup/` | 原厂分区备份(git 忽略) |

## 参考

- pmOS venus 页面:https://wiki.postmarketos.org/wiki/Xiaomi_Mi_11_(xiaomi-venus)
- pmOS pdx215 页面:https://wiki.postmarketos.org/wiki/Sony_Xperia_1_III_(sony-pdx215)
- SM8350 平台主线状态:https://linux-msm.github.io/mainline-status/soc/sm8350
- Vanilla Mobile NixOS:https://github.com/vanilla-mobile-nixos/vanilla-mobile-nixos
- chayleaf OnePlus 6 NixOS 博客:https://pavluk.org/blog/2023/12/19/oneplus_6.html
- Matrix:`#sm8350-mainlining:matrix.org`
- 小米 venus 下游内核开源树:MiCode/kernel_devicetree `venus-r-oss`(面板时序参考)
