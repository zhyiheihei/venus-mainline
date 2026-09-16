# porting notes

按里程碑追加日志,格式:`## M<n> · 日期 · 一句话结论`,下面记操作、输出、坑。

## M1 · 2026-09-16 构建侧完成

- 内核 7.2.6(mainline stable)编译通过,产物 venus-boot.img 15.7MB(header v4,kernel Image.gz + venus dtb,无外部 ramdisk)
- venus.dtb 79KB,含 ufs_mem_hc/usb@/ramoops/memory@80000000 节点
- busybox(Alpine static aarch64)initramfs 已内嵌,cpio TRAILER 验证通过;init 起 NCM+ACM gadget
- 已知非阻塞项:syncconfig 对 ARM 新架构符号(MTE/SME/LSUI 等)交互提示,取默认值
- 构建工作区在 ~/.cache/venus-kernel(本地盘):Documents 为 FUSE,并发编译会随机 ENFILE

手机侧验收(fastboot boot venus-boot.img 后):主机应见 USB NCM 网卡,host 配 10.15.0.1/24 后可 ping 10.15.0.2;ACM 串口(/dev/ttyACM0)进 busybox shell;dmesg 有 UFS 探测记录。

## M0 · 2026-09-16 调整

不做分区备份(2026-09 决策:不留原系统)。理由:可能改写的 boot/dtbo/vbmeta/vendor_boot/userdata 在 LOS fastboot 包与小米线刷包里都有现成镜像,可随时重刷;不可再生的 persist/modemst 在红线清单内永不触碰。

唯一准备项:电脑备一份 LOS venus 完整 fastboot 包(或小米线刷包),即全量回退手段。

## 当前已确认的关键事实

- venus 无 SD 卡槽,rootfs 必须走 UFS(userdata),无插卡退路
- pdx215(同平台)的 UFS 在 mainline 被禁用是 Sony 特有历史 bug(误擦全盘),高通参考设计 UFS 平台层 5.13 即通,venus 风险待 M2 实测
- WiFi WCN6855 驱动(ath11k)在笔记本侧成熟,sm8350 手机板级供电框架(qca6390-pmu)2026-06 才为 HDK 打补丁且尚未进主线
- 面板 dsi-panel-k2b-38-08-0a-dsc-cmd(1440p DSC bpp=30),下游时序在 MiCode/kernel_devicetree venus-r-oss 树
