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

## M1 · 2026-10-23/24 · 首次真机引导: v3 到达 init, v4 秒死待查; 一次全量恢复 EvoX 的完整事故记录

### 时间线与实证

- `fastboot boot` 内存引导在 venus 的 ABL 上**不可用**: v4(11.8MB) 发送 rc=0 但静默不执行 (vs v2/v4 header 均如此), 放弃该路径。
- `fastboot flash boot_a + continue`(slot a, EvoX vbmeta 原版在位) **可以引导自编 mainline 7.2.6**: 用户观察"进入系统但卡死" = init v1 (exec sh → console EOF → panic) 的设计缺陷, 非内核问题。**SM8350 venus 主线内核启动证实。**
- init v1 的 panic 循环把 a 槽 tries_remaining 烧光 → `getvar slot-unbootable:a = yes`; 之后对 a 槽任何 flash+continue 都报 `Failed to load image from partition: Load Error`。b 槽 (原装 EvoX) 也因多次 set_active/失败周期进入 unbootable → 开机直落 fastboot。
- `set_active X` 可给槽位一次全新引导窗口 (观测 3 次 OKAY); 但每次失败的内核引导又会烧光 tries。**教训: 验证性引导只烧一次, 失败必须先修内核再引导, 禁止反复 continue。**
- 2026-10-24 下午按 EvoX 官方 First Time Install 完整重装 (boot_ab/dtbo_ab/vendor_boot_ab 双槽 + Format data + adb sideload 官方 3.7GB OTA, Windows 通道), 双槽全恢复原装, 手机复活进入系统。**证实全程无硬件问题。**

### 误判记录 (引以为戒)

1. **电池论**: 曾归因电量, 被用户证伪 (从未拆机)。字节级全同的镜像在不同时刻引导结果不同, 真因是槽位 tries 状态, 而非供电。
2. **"max-download-size" 误读**: `Requested download size is more than max allowed` 出现时多为**传输断连**的罐头报错, 实测 getvar 报 768MB 且 192MB flash 可行。
3. **fastboot boot 沉默**: 曾怀疑 header v4 不被支持并重打 v3, 实际该命令根本未执行, 与 header 无关。
4. ** ramoops 地址错误**: init 版本 v3 起把 ramoops 从 sagami 抄来的 0xffc00000 改为 venus 真实地址 0xa9000000/2MB (来源: EvoX vendor_boot DTB 反编译, `qcom: ramoops` 节点)。此前所有"读黑匣子失败"皆因地址错。
5. 全程未建可靠的内核日志通道就开始反复试引导, 违反"先有观测再动手"的原则。

### 当前设备状态 (2026-10-24)

- 双槽 = 原装 EvolutionX 12.3 (Android 17, 20261023), userdata 已清空, vbmeta 原版 (flags=3)。
- Windows 主机 (moli-desktop) 已装 Google USB driver (含 18d1:d00d) + platform-tools 37; adb/fastboot 通道稳定, sideload 3.7GB 成功。
- 镜像资产: evox boot/dtbo/vendor_boot/vbmeta + 官方 OTA zip 均在 `~/mi11-work/`; 自编内核 v3/v3b/v4 + 补丁版 vendor_boot 在 `~/mi11-work/images/`。

### M1 手机侧验收结论

- [x] `fastboot flash` 通道可用 (Windows + 驱动)
- [x] mainline 内核可在 venus 启动至 initramfs (v3 实证)
- [ ] **v4 秒死原因待查**: v4 = v3 + init v4(永不退出版) + DTB ramoops 节点改址 (0xa9000000, console+record+pmsg 布局)。下一步: 从活的 EvoX 读 `/dev/pmsg0` (2MB 全 region 原始 dump, v4 console 文本应可辨识), 取得死亡现场后再修正。
- [ ] UFS / USB NCM gadget 验收未开始 (依赖上条)

### 操作纪律 (新增红线)

- 引导验证 = flash + set_active + continue 一气呵成, **只引导一次**; 引导失败优先恢复 pmsg0 证据, 禁止无证据重试。
- 不在手机上做任何"试试看"式的连续实验; 每个动作先写进 notes 预期结果。
- 官方恢复路径: EvoX 官方 First Time Install (本文记录) 永远有效, 资产常备 `~/mi11-work/`。
