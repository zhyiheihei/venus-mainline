# porting notes

按里程碑追加日志,格式:`## M<n> · 日期 · 一句话结论`,下面记操作、输出、坑。

## M0 · 待开始

备份清单(venus 分区名,安卓 root 下 `dd` 后 `adb pull` 到 `backup/`):

- boot_a boot_b
- dtbo_a dtbo_b
- vbmeta_a vbmeta_b
- vendor_boot_a vendor_boot_b

另备:小米11 官方线刷包 或 LOS venus 完整 fastboot 包(存电脑,不入 git)。

## 当前已确认的关键事实

- venus 无 SD 卡槽,rootfs 必须走 UFS(userdata),无插卡退路
- pdx215(同平台)的 UFS 在 mainline 被禁用是 Sony 特有历史 bug(误擦全盘),高通参考设计 UFS 平台层 5.13 即通,venus 风险待 M2 实测
- WiFi WCN6855 驱动(ath11k)在笔记本侧成熟,sm8350 手机板级供电框架(qca6390-pmu)2026-06 才为 HDK 打补丁且尚未进主线
- 面板 dsi-panel-k2b-38-08-0a-dsc-cmd(1440p DSC bpp=30),下游时序在 MiCode/kernel_devicetree venus-r-oss 树
