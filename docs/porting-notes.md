# porting notes

按里程碑追加日志,格式:`## M<n> · 日期 · 一句话结论`,下面记操作、输出、坑。

## M0 · 待开始

不做分区备份(2026-09 决策:不留原系统)。理由:可能改写的 boot/dtbo/vbmeta/vendor_boot/userdata 在 LOS fastboot 包与小米线刷包里都有现成镜像,可随时重刷;不可再生的 persist/modemst 在红线清单内永不触碰。

唯一准备项:电脑备一份 LOS venus 完整 fastboot 包(或小米线刷包),即全量回退手段。

## 当前已确认的关键事实

- venus 无 SD 卡槽,rootfs 必须走 UFS(userdata),无插卡退路
- pdx215(同平台)的 UFS 在 mainline 被禁用是 Sony 特有历史 bug(误擦全盘),高通参考设计 UFS 平台层 5.13 即通,venus 风险待 M2 实测
- WiFi WCN6855 驱动(ath11k)在笔记本侧成熟,sm8350 手机板级供电框架(qca6390-pmu)2026-06 才为 HDK 打补丁且尚未进主线
- 面板 dsi-panel-k2b-38-08-0a-dsc-cmd(1440p DSC bpp=30),下游时序在 MiCode/kernel_devicetree venus-r-oss 树
