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

## 2026-10-24 深夜 · 借鉴 pdx206-mainline 的关键发现(同 SM8350 平台成功移植)

来源: https://github.com/terminal-index/pdx206-mainline (Sony Xperia 5 II, SM8350, mainline 成功移植全套文档)

### 致命 bug(我们的): init 缺 `busybox --install -s /bin`

pdx206 init 的第一步就是它。我们的 initramfs 只有 /bin/busybox + /bin/sh,
mount/dd/ip/telnetd/dmesg/reboot 全是 busybox applet, 不 install 就不存在:
- `mount -t configfs` → not found 静默失败 → configfs 从未挂载 → UDC 永远不出现(USB 之谜真凶)
- `dd` → 不存在 → misc/尾部日志永远空(rd9-rd12 全 0 行的原因)
- `reboot` → 不存在 → v12 的 74s 回 fastboot 实为 PMIC 硬件看门狗超时, 非我们的 beacon
- v3 当年"能启动"是因为 init v1 只用了 echo/sleep 等 builtin, 碰巧活到了 exec sh

### pdx206 经验清单(逐条对照我们)

1. cmdline 三连必须加: `regulator_ignore_unused pd_ignore_unused clk_ignore_unused`
   - 无面板/音频驱动的最小 initramfs, 内核 ~30s 后 regulator_late_cleanup 会关掉
     未认领电源轨(USB PHY 的 vdda 也在内) → I2C/USB 全挂 → 无 panic 死机
2. 硬件看门狗: XBL 启动即开 ~32s 倒计时, 必须有狗不喂就硬复位(无 panic 无 ramoops)
   - 修: CONFIG_QCOM_WDT=y + init 里 `busybox watchdog -t 5 /dev/watchdog &` 兜底
3. Hybrid DTB: 主线 DTB + 厂商 DTB 拼接成 pool, ABL 验厂商的, 内核选自己的
   - venus 变体: 我们用 vendor_boot 装小米 DTB + boot 装主线内核, 同效
4. USB 网络用 RNDIS+172.16.42.x(pmOS 标准), 宿主机跑 auto_ip 循环自动配 IP
5. init 顺序: busybox --install → kmsg banner → 挂 proc/sys/dev/pts → loglevel 7 →
   gadget → watchdog → 等存储 → 挂 root → switch_root; 失败进 rescue shell

### v14/v15 修复内容

- v14: QCOM_WDT=y + init watchdog 兜底 + cmdline 三连(已刷, 但 init 的 sed 语法错 &; 未验)
- v15: busybox --install 修复(本次根因) + init 语法修正, 待刷
- 状态机备忘: 刷 X 后引导验证只烧一次; 读日志 = 引导 v1x 写 misc → 刷 EvoX boot →
  reboot recovery → sideload 读 misc 打屏(venus-init 行数>0 即成功)

## 2026-10-24 深夜二 · v15 循环未解, misc 日志通道建成, 交接

- v15(busybox --install + watchdog + cmdline 三连)仍 ~90s panic 循环 → 根因未知, **但 v15 死前的 dmesg 已由 init 每 15s 写入 misc 偏移 4KB 起**
- 读取工具链已建成: rd14(打印 misc 日志精华 ~15 行)在 Windows C:\Users\<windows-user>\mi11\; 流程见 docs/HANDOFF.md 第四节
- 完整交接文档: **docs/HANDOFF.md**(设备状态/已证事实/坑位清单/下一步路线), 新 agent 从那里开始
- 本日新增实证: fastboot continue 仅新鲜会话可靠; recovery/sideload ui_print 不回流 adb; recovery 无 /dev/mem 且 sysfs block 被锁; by-name 解析可用; BCB boot-recovery 在小米 ABL 上无效; VMware 抢 Windows USB 总线需重插

## 2026-10-24 夜 · 观测通道与 DTB 来源全部查清(推翻前面几处结论)

设备已恢复: EvoX17 在 slot a 正常运行, 已装 Magisk v30.7 并给 adb shell 授权 root,
`adb shell su -c id` = uid=0。刷机从 NixOS 侧用 `tools/win.sh` 驱动 Windows 主机。

### 已证事实(均有命令输出为证)

1. **misc 通道此前全空的原因不是 UFS 不通, 而是 init 找不到 misc 节点**:
   `dd if=/dev/block/by-name/misc` 在主机侧能读出 4MiB, 但我们的 initramfs 没有 ueventd,
   `/dev/block/by-name/*` 不存在。内核 `block/partitions/core.c:260` 给分区 uevent 加了
   `PARTNAME=%s`, 所以 init 应遍历 `/sys/class/block/*/uevent` 找 `PARTNAME=misc`。
   实测 misc 4MiB 里只有 34 个非零字节(BCB `bootonce-bootloader` + 0x8000 起 ABL 的槽位记录),
   v13–v16 一行日志都没写进去。
2. **`mkbootimg.py` 在 header_version>=3 时静默丢弃 `--dtb`**(源码 262-268 行),
   所以 v3/v15 那批镜像根本没有 DTB 段, 内核一直用的是 ABL 给的 DTB。
3. **venus 的 base DTB 来自 dtbo 分区, 不在 boot.img / vendor_boot**:
   `dtbo.img` 偏移 ~13552199 处有 model="**Venus based on Qualcomm Technologies, Inc SM8350**"
   的完整 DTB; vendor_boot 的 dtb 段是通用池(KATMAI/Lahaina/Yupik 六份, 与本机无关)。
   本机权威身份: compatible="qcom,lahaina-mtp","qcom,lahaina","qcom,mtp",
   `qcom,board-id=<0x10008 0x0>`, `qcom,msm-id=<0x19f 0x20001 0x1c8 0x20001 0x1f5 0x20001>`,
   `bootargs` 里还有 `androidboot.dtb_idx=4`(ABL 从表里挑的表项)。
4. **内存布局**(ABL 自己填进 memory 节点, 从 Android 运行中的 /sys/firmware/fdt 读到):
   `<0x80000000 0x39700000>, <0x180000000 0x100000000>, <0xc0000000 0xc0000000>`;
   8GB 机型, MemTotal 7.4GB。我们 DTS 原来写死 2GiB 是错的 —— ABL 把 initrd 放在
   0xaeb58000, 落在 2GiB 之外, 内核解不开 initrd 就会立刻死。
5. **ABL 把 vendor_boot 的 vendor ramdisk 当 initrd 交给内核**
   (Android 的 chosen 里有 `linux,initrd-start=0xaeb58000` / `end=0xafffe7d4`)。
   → 想让自建 `/init` 跑, 必须替换 vendor_boot 里的 vendor ramdisk。
6. **测量手段**: 主机侧测 `fastboot reboot` → fastboot 重新出现的间隔(本地 PowerShell 轮询),
   6 秒 = ABL 引导尝试后立刻落回 fastboot(内核大概率没跑起来), 30 秒以上 = 内核跑过。
   加 `panic=30` 可区分「内核 panic 后挂 30s」与「根本没引导」。

### 仍未解 / 下一步

- 用「EvoX 原厂 vendor_boot + 我们的 boot_b(v3)」实测: 该组合 v16 曾长时间不回 fastboot
  (即内核跑过), 而 v23–v27(自建 vendor_boot)每次都在 6 秒内落回 fastboot →
  **嫌疑集中在「自建 vendor_boot 被 ABL 拒绝」**(尺寸/AVB 描述符/表结构)或「我们的 DTB 让内核早死」。
  下一步用同一套计时法做单变量: 保持 boot_b 不变, 只把 vendor_boot 换回原厂, 看间隔变不变。
- 若确认是 vendor_boot 被拒: 用与厂商相同长度/结构的镜像(ramdisk 补齐到原长度), 或改为
  把 init 放进 boot.img 的 ramdisk(需先解决 ABL 是否使用它)。
- 串口(0x98c000)是我们唯一真正的"标准输出", 但没物理引出; 因此短期仍需靠
  「重启延迟编码 + misc 日志」两条通道。

## 2026-10-25 · 三个硬结论（推翻"改 DTS 没用"的旧解释）

### 1. 内核确实在 init 之前 panic（三点线性证据）

| cmdline | 观测周期 |
| --- | --- |
| `panic=30` | 35 s |
| `panic=120` | 125 s |
| `panic=15` | 20 s |

周期 = 引导约 5 s + panic 超时，**严格线性**。而且 stage 0（关掉 UFS/USB/显示，只留稳压器与 tlmm）
依旧是 20 s —— 说明 panic 与这些外设无关，发生在更早的阶段。

### 2. 我们此前自建的 vendor_boot 全是坏的（header 字段写错偏移）

vendor_boot v3 header 里 `dtb_size` 在 **偏移 2100**、`dtb_addr` 在 2104。
之前我一直把 dtb_size 写到 2080（那其实是 `name` 字段的开头），于是复制原厂 header 后
`dtb_size` 仍是原厂的 **7998176 (7.6 MB)**，而镜像里只有几百 KB 的 dtb →
ABL 按 7.6 MB 去读、越过文件末尾 → 直接判失败（这就是那几次"刷了自建 vendor_boot 就 6 秒回 fastboot"）。

原厂镜像实测：`vendor_ramdisk_size=20346309`（19.4 MB），`dtb_size=7998176`（7.6 MB），
`dtb_addr=0x1f00000`，总大小 96 MB。

### 3. ABL 把 **vendor_boot 的 vendor ramdisk** 当 initrd 交给内核

Android 运行中的 chosen 有 `linux,initrd-start=0xaeb58000`，而 boot.img 的 ramdisk 会被加载到
`ramdisk_offset 0x01000000`（= 0x81000000）。两者不是同一个位置。
我们从头到尾只改过 boot.img 的 ramdisk，**所以我们的 /init 很可能一次都没有被执行过** ——
这与"无论怎么改 DTS 都是同样的 panic 周期"完全吻合。

### 下一步（单变量、决定性）

`vendor_boot_b` = 原厂镜像 + **只把 vendor ramdisk 换成我们的 initramfs**，其余（header 的
dtb_size/dtb_addr、7.6 MB 的 dtb pool、96 MB 总大小、AVB footer）全部原样保留，避免 ABL 拒绝。
`boot_b` 保持 stage 0（init 里 `sleep 120`）。

判读：周期变成 **约 130 s** → 我们的 init 终于跑起来了，观测通道打通；
仍是 **20 s** → init 仍未执行，回去查 initrd 传递。

产物：`~/mi11-work/images/vendor_boot-venus-vb28.img`（sha256 前缀 e248c893c125c7f6）

### 参考的成熟做法（本轮学习，出处见 docs/references.md）

- U-Boot 文档 "Hang/crash bisection"：无日志时先看三件事（设备是否断开 / 黑屏挂死 / 重启或 crashdump）；
  逐个关驱动再逐个打开（pinctrl、mmc、scsi/ufs、usb dwc3、phy、以及 framebuffer 节点里的 clock 引用）；
  屏幕日志要求 DTB 带 label 且 reserved-memory 用下游命名 `cont_splash`
- Linaro：`cat Image.gz dtb > Image.gz+dtb` + `mkbootimg`，`earlycon`，dtbo 写零而不是 erase
- U-Boot/lk2nd：`fastboot oem log` 可取引导器 log buffer，`fastboot oem run` 可执行任意命令（可用来 dump 内存）

## 2026-10-25 · 里程碑: UFS 通 + USB 控制台通 + 交互 shell(观测通道彻底打通)

### 两个真正的根因, 都是 **内核配置**, 不是设备树

1. **UFS 起不来** → `CONFIG_PHY_QCOM_QMP_UFS` 与它的父开关 `CONFIG_PHY_QCOM_QMP` 都没开,
   SM8350 的 QMP UFS PHY 驱动根本不存在, `phy@1d87000` 从不 probe → 没有任何块设备。
   打开后立刻出现 `sda`(34 个分区) 与 sdb..sdf 四个 LUN。
2. **USB 没有 UDC** → SM8350 的 USB2 PHY 用的是 `qcom,usb-snps-hs-7nm-phy`(Femto V2 驱动),
   而 `CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2` 原本是 `=m`(模块)。initramfs 启动没有 rootfs 去加载模块,
   于是 PHY 永不 probe, dwc3 一直 `deferred: supplier 88e3000.phy not ready`, `/sys/class/udc` 恒为空。
   改成 `=y` 后: `a600000.usb` 成为 UDC, gadget 绑定成功, 主机侧枚举
   `USB\VID_18D1&PID_4EE1\VENUS-M1`(ACM + NCM)。

**教训**: 在只有 initramfs 的启动路径上, 任何依赖 `=m` 的驱动都等于不存在。凡是启动链上
必需的(PHY/gadget/ufs), 必须 `=y`。

### 另一处导致误判的 init 写法

init 里如果裸写 `sleep`/`dd` 等命令, 依赖 `busybox --install -s /bin` 是否成功。一旦失败,
init 会在中途退出, 内核 `Attempted to kill init` panic → 表现为"固定周期的重启循环",
极易被误读成"init 没跑到"。**所有关键命令一律写成 `/bin/busybox xxx` 绝对路径。**

### 现在的调试工作流(不再需要反复刷机)

- 手机跑我们的内核时, 主机侧出现 USB CDC-ACM 串口(**Windows 上是 COM3**),
  手机侧 `/init` 在 `ttyGS0` 上开了交互 shell, 并会先把 dmesg 打出来。
- 主机侧用 PowerShell 的 `System.IO.Ports.SerialPort` 打开 COM3(115200 8N1)即可:
  读实时 dmesg、发任意命令(`dmesg`、`cat /proc/partitions`、`ls /sys/...`)。
- 本机留档: `/tmp/serial_clean.txt`(去转义后的 376 行 dmesg)。
- 启动配方(实证可用): `header_version 1` + `Image.gz + venus.dtb` 拼接 + `boot_b` +
  **erase dtbo_b** + `set_active b`; initramfs 同时塞进 boot.img 的 ramdisk
  (以及用原厂 vendor_boot 只替换 vendor ramdisk 的 vb28 镜像)。

### 现场 dmesg 里剩下的未完成项(下一步清单)

```
arm-smmu 3da0000.iommu: probe with driver arm-smmu failed with error -110   # GPU 的 SMMU
platform gpio-keys: deferred probe pending: (reason unknown)                # 依赖 pm8350_gpios(阶段一被关)
qnoc/gcc: sync_state() pending due to 3d6a000.gmu / 3d90000.clock-controller / 3da0000.iommu
regulator: Not disabling unused regulators                                  # 正常(regulator_ignore_unused)
```
→ 说明 venus.dts 里 GPU(GMU/GPUCC/SMMU) 这套还挂着, 需要在阶段二里要么补固件要么显式关掉;
`gpio-keys` 依赖 `pm8350_gpios`, 打开 gpio 组即可。

## 2026-10-25 · 调试回路彻底闭环(不再需要 fastboot)

### 通道
- **主**: USB NCM 网络 + netcat shell —— 手机 `10.15.0.2:9000`, 主机 `tools/ncsh.sh "<命令>"`;
  init 里用 `mkfifo` + `cat | sh -i | nc -l -p 9000` 常驻循环。不走 tty 行规程,
  所以反复开关 COM3(DTR 掉线导致 tty hangup)也不会把它弄死 —— 这是之前串口 shell 反复失联的根因。
- **备**: ttyGS0 上的串口 shell(每次循环重新 `exec 3<>/dev/ttyGS0`, 带 2s 退避)。
- **兜底**: init 把 dmesg 写进 misc 偏移 1MiB。

### 分区真相(venus 的 boot 等分区在 sde 这个 LUN 上, 不在 sda)

```
sda  116G  → sda1..sda34: switch/ssd/…/misc(sda11)/…/super(sda29)/vbmeta_system_a,b(30,31)/rescue(33)/userdata(34)
sde  3.0G  → 71 个分区, 含 boot_a(sde12) boot_b(sde38) vbmeta_a(15) vbmeta_b(41) dtbo_a(16) dtbo_b(42)
              vendor_boot_a(24) vendor_boot_b(50) vm-bootsys_a/b
```

### 自助更新内核(已实测)

```sh
tools/update-kernel.sh <boot.img> [--reboot]
# 内部: push 镜像到 /tmp/boot.img → 手机上按 PARTNAME 找 boot_b(实测 /dev/sde38)
#      → dd bs=1M → sync → 可选 reboot -f
```
实测输出: `boot_b -> /dev/sde38`、`12888064 bytes copied, 163.8MB/s`、`FLASH_DONE`,
随后 `reboot -f` 重新起来并正常响应 —— **fastboot 从此只用于救砖**。

## 2026-10-25 · Alpine 上机 + 硬件逐个点亮

### 已跑通（有实测输出）

| 项目 | 证据 |
| --- | --- |
| **真实发行版用户态** | `cat /etc/alpine-release` → `3.24.3`；`ps` 里 PID 1 = `/sbin/init`(OpenRC)；内核 7.2.6 |
| **持久根文件系统** | `/dev/sda29`(super 分区, 9.1GB) 格成 ext4(标签 venusroot)，`grep sda29 /proc/mounts` → 挂为 `/`；重启后 `/root/persist-test.txt` 仍在 |
| **USB 网络 + 命令通道** | 手机 `10.15.0.2/24`；主机一条命令 `tools/vcmd.sh "..."`(2 秒)；`tools/vpush.sh` / `tools/vpull.sh` 传文件 |
| **帧缓冲控制台** | `/sys/class/graphics/fb0` → `simpledrmdrmfb 1440,3200,32bpp`(复用 ABL splash，无需 DSI 驱动) |
| **按键** | `/proc/bus/input/devices` → `gpio-keys`，`event0` |
| **RTC** | `/sys/class/rtc/rtc0` 出现(需 `CONFIG_NVMEM_SPMI_SDAM=y` + `&pmk8350_sdam_2` okay) |
| **I2C** | `/dev/i2c-0..4`，i2c-3 上有 2 个从设备(0x40/0x42) |
| **热传感器** | thermal_zone 多个：cpu/aoss ~33℃ |
| **PCIe 主控** | `1c00000.pcie` 起来，root port `0000:00:00.0 [17cb:010c]` |
| 稳压器 | 39 个 |

### 尚未跑通

- **WiFi(qca6490)**: 下游 DTB 实测 `wlan-en-gpio=tlmm64`、`bt-en=65`、`sw-ctrl=153`，
  `qcom,wlan-rc-num=0`(即 pcie0)；电源 `pmr735a_s2/pm8350_s11/pm8350_s10/pm8350c_s1/pm8350_s12/pmr735a_l7`。
  已把 wlan_en(GPIO64)/bt_en(GPIO65) 做成 fixed-regulator 并置 always-on、补上 s11/s12 —— 仍然
  `qcom-pcie: Device not found`(端点未 link)。下一步要动 perst 时序/refclk 与 ath11k 固件。
- **充电/电池**：`/sys/class/power_supply` 为空(下游走 pmic_glink/UCSI，主线需另配)
- **触摸/音频/GPU**：未开始（GPU 的 `arm-smmu 3da0000.iommu` probe 仍 -110）

### 关键工具（都在本机跑，不依赖 Windows PowerShell）

```
tools/vcmd.sh "<命令>"            手机上执行命令(约 2 秒)
tools/vpush.sh <本地> <手机路径>   推文件(手机主动连出, 稳定)
tools/vpush-big.sh <本地> <路径>   大文件(设备侧监听 9500, 实测 16MB 稳定)
tools/vpull.sh <手机> <本地>       取文件
tools/serial.sh "<命令>"          串口(COM3)通道, 主通道挂了时用
tools/serial-login.sh "<命令>"    getty 登录后再执行(空密码 root)
tools/serial-put.sh <本地> <路径>  只用串口写小文件(救援)
tools/device-run.sh / cmd.sh      PowerShell 版(备用, 慢)
```

Windows 侧一次性设置（portproxy，重启后仍有效）:
```
netsh interface portproxy add v4tov4 listenport=9222 listenaddress=<LAN_WINDOWS_IP> connectport=9000 connectaddress=10.15.0.2
netsh interface portproxy add v4tov4 listenport=9223 listenaddress=<LAN_WINDOWS_IP> connectport=9001 connectaddress=10.15.0.2
netsh interface portproxy add v4tov4 listenport=9310 listenaddress=<LAN_WINDOWS_IP> connectport=9500 connectaddress=10.15.0.2
netsh interface portproxy add v4tov4 listenport=9600 listenaddress=10.15.0.1 connectport=9600 connectaddress=<LAN_HOST_IP>
netsh interface portproxy add v4tov4 listenport=9601 listenaddress=10.15.0.1 connectport=9601 connectaddress=<LAN_HOST_IP>
```
（`10.15.0.1` 要由 `New-NetIPAddress -InterfaceIndex <Ncm网卡> -IPAddress 10.15.0.1 -PrefixLength 24` 配上）

### 根文件系统怎么来的

`super`(sda29) 用交叉编译的静态 `mke2fs`(nix: `pkgsCross.aarch64-multiplatform.pkgsStatic.e2fsprogs`) 格成 ext4，
把 initramfs 里的 Alpine 全量 `cp -a` 进去，写 `/venus-root` 标记；initramfs 的 `/init` 优先
mount sda29 → `switch_root` → `/venus-init.disk`；失败则退回内存版 Alpine（双保险）。

### 待办

1. 恢复：把 `venus-boot-v53`(纯内存 rootfs, 最稳) 刷回 boot_b，再从长计议
2. WiFi：perst/refclk 时序 + ath11k(=y) + 固件 board-2.bin
3. 充电/电池（pmic_glink 或 pm8350b 充电器驱动）
4. 屏幕：确认 fbcon 文字是否真能在屏上看到（需要人眼）
5. GPU/音频/触摸

## 2026-10-25 · 设备上原生 Nix 跑通（NixOS 的前置条件）

### 结果

```
$ /nix/var/nix/profiles/default/bin/nix --version
nix (Nix) 2.28.3

$ nix build nixpkgs#hello      # 经代理从 cache.nixos.org 取 aarch64 二进制
$ /nix/store/...-hello-2.12.3/bin/hello
Hello, world!
```

也就是说：**这台手机现在是一个能联网、能从官方二进制缓存安装 aarch64 包的 Nix 机器**。

### 怎么做到的（三个坑）

1. **Nix 单用户安装**：官方 `install --no-daemon` 在 root 下会抱怨，需要先
   `mkdir -m 0755 /nix`、建 `nixbld` 组和 8 个 `nixbldN` 用户、写
   `/etc/nix/nix.conf`(`build-users-group = nixbld`)，并且 **`mount -t devpts devpts /dev/pts`**
   （否则 `nix profile install` 因 `opening pseudoterminal master` 失败）。
2. **设备上网**：手机没有 WiFi 驱动，走 USB 网络 + 代理链
   设备 → `10.15.0.1:9610`(Windows portproxy) → `<LAN_HOST_IP>:8888`(本机 tinyproxy) → 外网。
   ```
   export http_proxy=http://10.15.0.1:9610 https_proxy=http://10.15.0.1:9610
   ```
   本机 tinyproxy 配置：`Port 8888 / Allow 10.15.0.0/24 / Allow 192.168.0.0/24`。
3. **TLS 证书错误(60) 的真因是系统时间**：设备从 RTC 起来时是 1970-01-01，
   证书不在有效期内。`date -u -s '<host time>'` 之后立刻正常。
   同时 `/etc/nix/nix.conf` 里加 `ssl-cert-file = /nix/store/...-nss-cacert-3.107/etc/ssl/certs/ca-bundle.crt`
   （单用户安装不写 profile，所以不会自动设 `NIX_SSL_CERT_FILE`）。

### 下一步（NixOS）

在设备上原生跑 NixOS 安装（8 核，二进制缓存可替换，不必交叉编译）：
`nixos-install --root <目标目录>`，然后让 initramfs 的 `/init` 把该目录 `switch_root` 起来。
需要先决定 NixOS 放哪：`sda29`(super, 8.3GB, 现在跑 Alpine) 还是重划 `sda34`(userdata, 105GB)。

## 2026-10-25 · **WiFi（QCA6490 / WCN6851 hw1.1）打通，设备可直连互联网**

### 结果（实测）

```
# ip -4 addr show wlan0
inet <LAN_PHONE_A>/24 brd <LAN_BROADCAST> scope global wlan0
# ip route
default via 192.168.0.1 dev wlan0 metric 303
# wget -qO- https://cache.nixos.org/nix-cache-info      ← 无代理！
StoreDir: /nix/store
WantMassQuery: 1
Priority: 40
```

手机自己连上了 `<WIFI_SSID>`（WPA2），拿到 <LAN_PHONE_A>，**直接访问 HTTPS，不再需要 USB 网络或代理**。

### 完整的通关步骤（每一步都有实测证据）

1. **PCIe 链路**：开机时 WiFi 电源没开 → `qcom-pcie: Device not found`。
   在用户空间把五路电源打开后 `unbind`/`bind` → `PCIe Gen.3 x1 link up`。
   为此给 `pcie-qcom` 补了 `remove` 回调（`dw_pcie_host_deinit`），否则重新 probe 会 `-ENOSPC`
   （旧的 host bridge 占着 domain 0）。
2. **电源必须在用户空间开**：在设备树里写 `regulator-always-on` 或改电压，会在开机早期挂死（实测 3 次）。
   改用 `regulator-output`（`compatible = "regulator-output"`）+ 自建 `voltage` 属性，
   运行时 `echo 1012000 > .../voltage; echo enabled > .../state` 即可。
3. **芯片识别**：QCA6490 报 `soc_hw_version 1 16`，主线 ath11k 只认 2.x，报
   `Unsupported WCN6855 SOC hardware version: 1 16`。
   这就是 Dmitry Baryshkov 的 **「wifi: ath11k: enable support for WCN6851」** 补丁系列
   （WCN6851 = SM8350 平台上的 WCN6855 早期版，自称 hw1.1）。把 [2/7] 那个补丁打进内核后：
   `ath11k_pci 0000:01:00.0: wcn6855 hw1.1` → 固件 `WLAN.HSP.1.1.c3-00260-...` 成功加载。
4. **板级数据（BDF）**：`board-2.bin` 是容器格式，我们手里的 bdwlan 是单个 BDF。
   关键点：**把厂商原始的 ELF 格式 bdwlan 直接当 `board.bin` 用** ——
   ath11k 看到 ELF 头就走 `ATH11K_QMI_BDF_TYPE_ELF` 分支，**跳过 CAL 数据**（`-2` 就是卡在它要我提供
   `cal-pci-0000:01:00.0.bin`）。改成原始 ELF 后立刻出 `wlan0` + `phy0`。

### 现在 WiFi 是怎么起来的（手动，待做成开机自动）

```sh
# 1) 打开 WiFi 电源（按下游 DTB 的 qcom,vdd-wlan-*-config）
for r in io dig rfa1 rfa2 aon; do
  echo <电压> > /sys/bus/platform/devices/regulator-wifi_$r/voltage
  echo enabled > /sys/bus/platform/devices/regulator-wifi_$r/state
done
# 2) 重新训练 PCIe 链路
echo 1c00000.pcie > /sys/bus/platform/drivers/qcom-pcie/unbind
echo 1c00000.pcie > /sys/bus/platform/drivers/qcom-pcie/bind
# 3) wpa_supplicant（静态 aarch64 版，来自 nix）
wpa_supplicant -B -i wlan0 -c /etc/wireless/wpa.conf
# 4) DHCP
udhcpc -i wlan0
```

### 遗留

- MAC 是 BDF 里的占位值 `00:03:7f:12:65:81`；真机 MAC 在 `persist/wlan_mac.bin`（后续补）
- 电压仍是 PMIC 设备树里的默认值（dig 752mV / aon 500mV 等），能工作但偏低；
  若要按下游值（1012mV 等）需要绕过"改电压即挂死"的限制（可能要用 `regulator_set_voltage` 在链路训练之后做）
- 以上四步目前是手工；下一步写成 `/etc/local.d/wifi.start` 开机自动执行

## 2026-10-25 · 调试通道全面切到 WiFi，USB 网络已关闭

### 现状

```
$ ip -4 addr show wlan0      # 手机侧
inet <LAN_PHONE_IP>/24 scope global wlan0     ← 固定地址, 每次开机都一样
$ cat /sys/class/net/wlan0/address
02:11:22:3c:4d:5e                            ← 固定 MAC
$ ls /sys/class/net
lo  wlan0                                   ← usb0 已消失
```

本机（NixOS）侧：
```
tools/vcmd.sh "<命令>"      走 <LAN_PHONE_IP>:9000/9001，2 秒一条
tools/vpush.sh / vpull.sh   走 WiFi 传文件
tools/serial.sh / serial-login.sh   走本机 /dev/ttyACM0（只剩 ACM 串口，没有网络功能）
```

### 三处必须记住的坑

1. **USB 网络必须从 gadget 里删掉**，不能只 `ip link set down`：
   解绑 UDC → `rm configs/c.1/ncm.usb0` → `rmdir functions/ncm.usb0` → 重新绑定 UDC。
   ACM 串口要保留（它是唯一的"没有网络也能说话"的通道）。
   持久化要改两处：`/venus-init.disk`（开机建 gadget）和 `/etc/local.d/venus.start`。
2. **MAC 必须固定**。BDF 里的 MAC 是占位值 `00:03:7f:12:xx:xx` 且**每次 probe 都变**，
   导致 DHCP 租约和 ARP 表错乱 —— 表现为「ping 得通但 TCP 一律 Connection refused」，
   因为主机的 ARP 把该 IP 指到了别的设备。固定成 `02:11:22:3c:4d:5e` 后立刻正常。
3. **IP 要固定**。DHCP 每次拿到 .132/.133/.134/.135/.136 不固定，工具全挂。
   现在 wifi.start 在 `carrier=1` 之后设 `<LAN_PHONE_IP>/24` + 默认路由 + resolv.conf。

### 开机自动流程（已实测重启后生效）

`/etc/local.d/venus.start` → 起调试通道 → 5 秒后调 `/etc/local.d/wifi.start`：
```
开五路电源 → unbind/bind pcie → 等 wlan0 → 固定 MAC → wpa_supplicant
→ 轮询 carrier=1 → 固定 IP <LAN_PHONE_IP> → 默认路由 + DNS
```
重启后实测：`wlan0 <LAN_PHONE_IP>`、`default via 192.168.0.1`、
`wget https://cache.nixos.org/...` 直接成功（无代理）。

## 2026-10-25 · 开发通道升级：SSH 取代 HTTP/nc

### 现在的主通道

```sh
ssh venus                  # ~/.ssh/config 里已配好: root@<LAN_PHONE_IP>, IdentitiesOnly
scp / tar over ssh         # 见 tools/vpush.sh、tools/vpull.sh
```

设备侧跑的是**静态编译的 dropbear**（nix: `pkgsCross.aarch64-multiplatform.pkgsStatic.dropbear`，
756KB），放在 `/usr/sbin/dropbear`，host key 在 `/etc/dropbear/dropbear_ed25519_host_key`（持久化在 ext4 上），
`/etc/local.d/sshd.start` 负责开机启动（已挂进 `venus.start`，sleep 3 后执行）。

主机侧 `~/.ssh/config`：
```
Host venus
    HostName <LAN_PHONE_IP>
    User root
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 15
```

### 三个坑

1. **OpenSSH 的新 scp 默认走 SFTP**，dropbear 没有 sftp-server → `scp -O`（legacy 协议）也不行，
   因为设备侧没有 `scp` 可执行文件。**结论：用 tar over ssh**：
   `tar -C dir -cf - base | ssh venus "tar -xf - -C dest"`（busybox tar 完全够用）。
2. **`dropbear -v` 不被接受**（会打 usage），要调试用 `-E`。`-p 22` 单独给也行。
3. **ssh agent 会干扰**：不加 `IdentitiesOnly yes` 时 agent 拒绝签名 → 表现为 `Permission denied`。

### 工具清单（全部走 WiFi，本机执行）

| 工具 | 作用 |
| --- | --- |
| `tools/vcmd.sh "<命令>"` | 远程执行（ssh），秒级 |
| `tools/vsh.sh` | 开交互 shell |
| `tools/vpush.sh <本地> <手机>` | 推文件/目录（tar over ssh） |
| `tools/vpull.sh <手机> <本地>` | 取文件/目录 |
| `tools/serial.sh` / `serial-login.sh` / `serial-put.sh` | `/dev/ttyACM0` 串口，网络全挂时用 |
| `tools/update-kernel.sh` | 换内核（dd 到 boot_b + 重启） |

设备主机名已设为 `venus`。

## 2026-10-25 · **里程碑：NixOS 25.05 在 venus 上跑起来（全自动，重启后无人干预）**

### 结果（重启 2 分钟后实测）

```
$ ssh venus
PRETTY_NAME="NixOS 25.05 (Warbler)"
uname -r            → 7.2.6                （我们自建的内核）
systemctl is-system-running → running      （无 failed unit）
ip -4 addr show wlan0 → <LAN_PHONE_IP>/24
ip route              → default via 192.168.0.1 dev wlan0
nix store ping        → Trusted: 1         （cache.nixos.org 可用，DNS/HTTPS 正常）
```

也就是说：**一台跑着自己内核、自己 WiFi、能装包的小米 11 NixOS**，开机能自己连网、自己起 ssh。

### 之前"100% 死机"的真正原因（串口日志实证）

```
mounting /dev/sda34 on /...
stage 2 init script (/mnt-root//init) not found
An error occurred in stage 1 ... Press r) reboot / *) ignore and continue
switch_root: can't execute '/init': No such file or directory
```

- NixOS 的 stage-1（`nixpkgs/nixos/modules/system/boot/stage-1-init.sh`）默认 `stage2Init=/init`，
  并检查 `<新根>/init` 是否存在；
- 而 `nixos-install --no-bootloader` **不会创建根上的 `/init` 符号链接**
  （正常安装里由引导器/activation 那一步建）。
- 于是 stage-1 挂好根却切不过去，PID1 起不来 → 表现为"内核活着、系统全黑"。

修法（都用上游支持的机制，不再手搓 stage-1）：
1. kernel cmdline 加 `init=/nix/var/nix/profiles/system/init`（stage-1 显式支持 `init=`，源码 187–198 行）；
2. initrd 前置脚本 `venus-preinit.sh` 顺手自愈：挂 `sda34`，缺 `/init` 就 `ln -s`；
3. 用 **NixOS 官方生成的 initrd**（`$system/initrd`，10MB zstd）当 ramdisk，
   boot.img = `Image.gz + venus.dtb + NixOS initrd`，cmdline 带 `console=ttyGS0,115200`。

### 第二个坑：固件压缩

NixOS 把 `hardware.firmware` 里的文件压成 `.zst`，靠内核 `FW_LOADER_COMPRESS_ZSTD` 读取；
我们的内核没开这个选项 → `Direct firmware load for ath11k/WCN6855/hw1.1/amss.bin failed with error -2`
→ MHI `-110` 超时 → ath11k probe 失败。
现在由 `venus-firmware` 服务把 `.zst` 解压到 `/var/lib/venus-fw`，并在 rebind 之前把
`/sys/module/firmware_class/parameters/path` 指过去（NixOS 自己会把它改回 store 路径，所以要后写）。

### 第三个坑：systemd 单元的 PATH

systemd 单元里 PATH 很窄，`ip`/`systemctl` 必须写绝对路径（`${pkgs.iproute2}/bin/ip`、
`${config.systemd.package}/bin/systemctl`），否则 `ip: command not found`。

### 现在的开机流程（全自动）

```
ABL → boot_b(自建内核+venus.dtb+NixOS initrd)
  → venus-preinit.sh: 建 USB ACM gadget + 自愈 /init → exec NixOS stage-1
  → stage-1 挂 sda34、switch_root → systemd
  → venus-firmware: 解压固件，设 firmware_class.path
  → venus-wifi-power: 开五路电源 → unbind/bind pcie → 等 wlan0 → 固定 MAC
                     → wpa_supplicant → 等 carrier → ip <LAN_PHONE_IP> → 重启 sshd
```

### 工具（本机）

```
tools/vcmd.sh "<命令>"     ssh 远程执行
tools/vpush.sh / vpull.sh  tar over ssh 传文件
tools/wserial.sh "<命令>"  走 Windows COM3（手机跑 NixOS 时的串口 shell）
tools/serial.sh           走本机 /dev/ttyACM0
```

### 待办

- 内核开 `CONFIG_FW_LOADER_COMPRESS_ZSTD` + `CONFIG_NF_TABLES`（可去掉固件解压服务、能开 NixOS 防火墙）
- kernel cmdline 加 `boot.shell_on_fail`（失败时可从串口按 `i` 拿 shell，不必再让人按键）
- 把 `/init` 符号链接正式写进安装流程（现在靠 preinit 自愈）
- 之后：屏幕/DSI、触摸、音频、GPU、充电

## 2026-10-25 · 往"正规 NixOS"推进（内核配置补齐 + 系统收尾）

### 这一轮做的事

1. **内核补齐关键配置**（都是之前靠变通绕过的）
   - `CONFIG_FW_LOADER_COMPRESS_ZSTD=y` → 可以直接吃 NixOS 的 `.zst` 压缩固件，
     删掉了 `venus-firmware` 解压服务，`firmware_class.path` 也不用再改
   - `CONFIG_NETFILTER` / `NF_TABLES`(+INET/IPV4/IPV6/ARP) / `NF_CONNTRACK` / `NFT_*` /
     `NETFILTER_XT_TARGET_LOG` / `XT_MATCH_LIMIT` / `NF_LOG_IPV4|IPV6` 等
2. **根上的 `/init` 符号链接正式建立** → `/init -> /nix/var/nix/profiles/system/init`
   （preinit 里的自愈逻辑保留作双保险）
3. **cmdline 加 `boot.shell_on_fail`**：stage-1 失败时可以在串口上按 `i`/`f` 直接拿 shell，
   不用再靠人按键进 fastboot 抢救
4. `nix.settings.auto-optimise-store` + `nix.gc`（每周清理，保留 14 天）

### 验证（重启后全自动）

```
uptime 126s / PRETTY_NAME="NixOS 25.05 (Warbler)" / uname -r 7.2.6
systemctl is-system-running → running
wlan0 <LAN_PHONE_IP>/24
/init -> /nix/var/nix/profiles/system/init
nix store ping → Trusted: 1
```

### 仍然遗留

- **NixOS 防火墙还没开**：`ip6tables (nf_tables): RULE_APPEND failed` —— nft 的 LOG 表达式在
  ipv6 家族里仍报缺模块。当前 `networking.firewall.enable = false`（局域网开发机，可接受），
  后续把 netfilter 符号补齐再开。
- 内核里还缺 GPU/DSI/音频相关的部分，等对应驱动开工时一起加。

### 内核构建/刷机流程（现在完全不用 fastboot）

```sh
# 主机: 编译
nix develop -c bash -c 'cd ~/.cache/venus-kernel/linux-build && make ARCH=arm64 \
  CROSS_COMPILE=aarch64-unknown-linux-gnu- -j10 Image'
# 打包: Image.gz + venus.dtb + NixOS 官方 initrd(取 $system/initrd 解压/直接用) + cmdline
# 推送 + 写入 boot_b（在设备自己身上 dd），再重启
tools/vpush.sh new-boot.img /root/boot.img
ssh venus "dd if=/root/boot.img of=/dev/sde38 bs=1M && reboot"
# 出问题: ssh 挂了就走 tools/wserial.sh（Windows COM3）或 tools/serial.sh（本机 ttyACM0）
```
备份：设备上留了 `/root/boot-good-nixos.img`（第一次成功的那版 NixOS 引导镜像）。

## 2026-10-25 · 硬件盘点（NixOS 上逐项核对）+ 仓库规范

### 已在 NixOS 上跑通的硬件

| 子系统 | 证据 |
| --- | --- |
| UFS | `/dev/sda`(34 分区) + `/dev/sde`(71 分区)，根 `/dev/sda34` |
| USB gadget | `/sys/class/udc` = `a600000.usb`；主机看到 18d1:4ee1（ACM 串口） |
| WiFi (WCN6851 hw1.1) | `ath11k_pci ... wcn6855 hw1.1` + `wlan0`，开机自动连 `<WIFI_SSID>` |
| RTC | `/sys/class/rtc/rtc0` = `rtc-pm8xxx c440000.spmi:pmic@0:rtc@6100` |
| 按键 | `/proc/bus/input/devices` → `gpio-keys` / `event0` |
| PCIe | `1c00000.pcie` → `0000:01:00.0`(ath11k) |
| 热传感器 | thermal_zone + hwmon0..11 |
| I2C | `/dev/i2c-*`（tlmm/qup） |
| GPU（Adreno 660） | **部分**：修好 `CONFIG_SM_GPUCC_8350`（原本是 `=m`，initramfs 阶段无驱动）后，`3da0000.iommu`(GPU SMMU) 探测成功、`sm8350-gpucc` 起来、`3d00000.gpu` 绑定 `adreno` 驱动；但 `msm_drm` 还没出 `/dev/dri/renderD128`（缺显示侧 mdss，属屏幕那一步） |
| 蓝牙（WCN6851） | **未完成**：固件已备好（`qca/hpbtfw21.tlv` + `hpnv21g.bin`，来自 `bluetooth` 分区的 FAT image/），但还没确定 venus 的 BT UART 是哪个 qupv3 SE，需要在 DT 里加 `bluetooth { compatible = "qcom,wcn6855-bt"; }` 子节点 |
| 充电/电池 | **被上游驱动缺失挡住**：`qcom_battmgr` 要走 `pmic_glink`→ADSP remoteproc；`pm8350b` 的 SMB 充电器主线没驱动。目前靠关机/ABL 充电 |

### 内核配置的几个"必须 =y"（都是 initramfs 阶段要用到的）

`PHY_QCOM_QMP_UFS`、`PHY_QCOM_USB_SNPS_FEMTO_V2`、`SM_GPUCC_8350`、`SM_GCC_8350`、
`FW_LOADER_COMPRESS_ZSTD`、`QCOM_LLCC`、`QCOM_OCMEM` —— 写成 `=m` 时在 initramfs 里等于不存在，
表现为"设备树明明有、驱动就是不 probe"。

`CONFIG_LOG_BUF_SHIFT` 从 17 改成 21（128KB→2MB）：之前 dmesg 只有 655 行，早起的 GPU/SMMU
报错全被冲掉，导致误判。这一条以后一直保留。

### 仓库规范

- 厂商固件**不进 git**（`nixos/firmware/` 已加进 `.gitignore`），用
  `tools/extract-firmware.sh` 从本机 `~/mi11-work/{mdm,vfw,btfw}` 重新生成
- NixOS 配置在 `nixos/configuration.nix`，部署用 `tools/deploy-nixos.sh [switch|boot]`
- 设备侧留了回滚镜像 `/root/boot-good-nixos.img`、内核镜像 `/root/b{84..90}.img`

## 2026-10-25 · 蓝牙（WCN6851）推进到 hci0，但 UART 没通

### 已确认的事实

1. **BT 挂在 uart18**（= qupv3 SE18 / qupv3_id_2，物理 0x890000），
   pins: CTS=gpio68 / RTS=gpio69 / TX=gpio70 / RX=gpio71，function `qup18`。
   依据：Android 运行时 DTB 里 `qupv3_se18_4uart: qcom,qup_uart@890000` 且 `status="ok"`
   （这是整机唯一一个 okay 的 4-wire UART，就是给 BT 的）。
2. **geni-serial 必须给 alias**，否则 `qcom_geni_serial 890000.serial: Invalid line -19`
   （驱动用 `of_alias_get_id("serial")` 决定 ttyGS/ttyMSM 编号）。加 `aliases { serial1 = &uart18; }` 后
   `/sys/bus/serial/devices/serial0-0` 出现，`hci0` 也随之注册。
3. **驱动要的固件名**（`btqca.c`）：TLV 先试 `qca/wcnhpbtfw<rom>.tlv` 再试 `qca/hpbtfw<rom>.tlv`；
   NVM 是 `qca/wcnhpnv<rom><variant>[.b<boardid>]`，GlobalFoundries 芯片 variant=`g`。
   这台机器 ROM 版本报的是 **0x10**，所以需要 `hpbtfw10.tlv` / `hpnv10*.bin`（不是 21）。
   固件来源：EvoX 的 `bluetooth` 分区（FAT），`image/` 下有 hpbtfw10/21 + 55 个 hpnv10.*。

### 现在的现象（不是"没通"，是"通了一半"）

```
hci0 已注册；boot 时:
  bluetooth hci0: Direct firmware load for qca/hpbtfw10.tlv failed with error -2
运行中 unbind/bind hci_uart_qca 后:
  Bluetooth: hci0: setting up wcn6855
  Bluetooth: hci0: command 0xfc00 tx timeout        ← UART 上的 HCI 命令没有回应
  Bluetooth: hci0: Reading QCA version information failed (-110)
```

两个独立问题：
- 启动时固件加载失败（-2）：`firmware_class.path` 在 BT probe(33s) 时还没指向含 `.zst` 的目录。
  已把 `firmware_class.path=/run/current-system/firmware` 写进 cmdline 并在 preinit 里再设一次，
  但 NixOS 的 udev 规则随后会覆盖成 store 路径（两者都含文件，仍需实测确认时序）。
- UART 没有数据往返（tx timeout）：说明 4-wire 配置还不对（可能需要 `qcom,wakeup-byte`、
  硬件流控 RTS/CTS、或 BT 使能/睡眠时钟的时序），这是下一步要查的点。

### 操作纪律（这次踩的坑）

- 一次重启循环事故：把 112 个固件文件塞进 NixOS 配置后 `nixos-rebuild switch` + `reboot -f`，
  设备进入循环。恢复办法是重刷最近一版可用 boot.img（v92）+ `set_active b` 后正常启动。
  **结论：蓝牙这类"换数据"的实验，先在运行时验证（改 `firmware_class.path` 指向临时目录、
  `unbind/bind`），不要直接进系统 generation。**
- `ssh venus` 挂在 `Server accepts key` 之后不动，是 ssh-agent 的问题，
  `~/.ssh/config` 里加 `IdentityAgent none` 解决。

## 2026-10-25 · 蓝牙（WCN6851）暂停，留档待续

状态：**hci0 能注册，但芯片不回 HCI 命令**。

已确证的事实（下次接手直接用）：
- BT 走 **uart18 = qupv3 SE18（0x890000）**，pins：gpio68 CTS / gpio69 RFR(RTS) / gpio70 TX / gpio71 RX；
  `gpioinfo -c gpiochip5` 里名字就是 `HST_BT_UART_*`，`HST_SW_CTRL`=gpio153。
- geni-serial 必须 `aliases { serial1 = &uart18; }`，否则 `qcom_geni_serial 890000.serial: Invalid line -19`，
  整条 UART 不注册、`/sys/bus/serial/devices/serial0-0` 不出现。
- DT 节点（已写进生成器）：`&uart18 { status="okay"; bluetooth { compatible="qcom,wcn6855-bt"; ... } }`
- **上游驱动支持的属性**（`hci_qca.c` 2478-2500 行）：`enable-gpios`（驱动自己做低 50ms→高 50ms 复位脉冲）、
  `swctrl-gpios`（读 SW_CTRL 判断芯片状态）、`max-speed`。已加进 DTS 并打包成 v98，**但没刷进去验证**。
- 固件名规则（`btqca.c`）：TLV 先 `qca/wcnhpbtfw<rom>.tlv` 后 `qca/hpbtfw<rom>.tlv`；
  NVM 是 `qca/wcnhpnv<rom><variant>[.b<boardid>]`，GlobalFoundries 芯片 variant=`g`。
  本机 ROM 版本报 **0x10**（不是 21），所以要用 `hpbtfw10.tlv` + `hpnv10.*`。
- 固件来源：EvoX 的 `bluetooth` 分区（FAT，用 mtools 读 `image/`），已由 `tools/extract-firmware.sh` 导出 112 个文件。

未解决的观察：即使做了「共享电源轨断电 + BT_EN 复位脉冲」，芯片仍然 `command 0xfc00 tx timeout`（-110）。
下次可试的方向：① 先刷 v98 用上游 `enable-gpios`/`swctrl-gpios` 机制；
② 检查是否需要 `firmware-name` 直接指定、以及 `.tlv` 是否需要非压缩副本（内核 fw loader 的 .zst 分支）；
③ 用 `gpioset` 直接驱动 68-71 做回环测试，确认 TX 物理上真的到芯片。

## 2026-10-25 · GPU（Adreno 660）跑通 —— 有量化数据

结论：**GPU 完全可用**（内核 + Vulkan + OpenGL 三层都实测通过）。

关键证据：
```
# 内核侧
/sys/kernel/debug/dri/1/gpu:  gpu-initialized: 1   revision: 660 (06060001)   ringbuffer 存在
dmesg: adreno loaded qcom/a660_sqe.fw, qcom/a660_gmu.bin → "Loaded GMU firmware v3.1.10"
dpu hardware revision: 0x70000000

# Vulkan（turnip）
deviceName = Turnip Adreno (TM) 660
driverName = turnip Mesa driver   driverInfo = Mesa 26.2.5

# OpenGL（freedreno）
EGL vendor: Mesa Project / 1.5      OpenGL core renderer: FD660  version 4.6
OpenGL ES 3.2 Mesa 26.2.5          renderer: FD660

# 基准
glmark2-es2-gbm --off-screen --size 1440x3200 -b :duration=0.5  → glmark2 Score: 413
glmark2-es2-gbm --off-screen --size 720x1600  -b :duration=0.3  → glmark2 Score: 949
kmscube 渲染 10 秒期间 GPU 频率从 315MHz 升到 676MHz（devfreq 生效）
```

打通顺序上的两个关键点：
1. **`88e7000.regulator`（QREFGEN）必须是可用模块**。它缺失时 DSI PHY 永久 deferred
   （`/sys/kernel/debug/devices_deferred` 直接写着 `ae94000.dsi platform: supplier 88e7000.regulator not ready`），
   msm 组件绑不齐，GPU 也就不会 probe。加载 `qcom-refgen-regulator.ko` 后一次成功。
2. **DRM 必须编成模块（=m）而不是内建**。内建时 mdss probe 在 initcall 阶段卡死，
   `/init` 根本没机会跑 → USB gadget 不出现 → 设备失联，只能靠按键进 fastboot。
   改成 =m 后可以运行时 insmod，probe 出问题也只影响那一次加载。

NixOS 侧配置（已进 nixos/configuration.nix）：
```nix
hardware.graphics = { enable = true; extraPackages = [ pkgs.mesa ]; };   # 生成 /run/opengl-driver（msm_dri.so + freedreno ICD）
systemd.services.venus-display = { ... };   # 开机按序 modprobe: qcom-refgen-regulator → cec → drm_* → msm → panel
```
模块文件放在设备 `/root/ko/`（由 tools/make-bootimg.sh 编译产物里挑出，见 docs 里列出的 11 个 .ko）。

面板现状：DSI 报告 `connected`、mode 1440x3200、crtc enable=1、backlight 设备存在（255/255），
但**屏幕全黑、背光不亮** —— 面板上电/初始化（DSC PPS + on 序列）还没在真机上验证成功，待续。

## 2026-10-26 · 显示/触摸/桌面这一轮的实测结论（回退前留档）

### 已证实可用（都有设备端输出为证）

| 能力 | 证据 |
|---|---|
| 面板上电+初始化 | `venus-k2: PPS + 压缩模式 rc=0` / `on 序列 rc=0` / `读 power_mode rc=1 val=0x9c`（0x9c = 厂商 DTB 里的 `panel-status-value`） |
| 背光 | `/sys/class/backlight/ae94000.dsi.0/` 存在，写 255 → 屏幕明显变亮 |
| 面板 DCS 双向通信 | `读 DDB rc=3` 能回读 |
| GPU | `adreno: loaded qcom/a660_gmu.bin`、`gpu-initialized:1`、turnip/freedreno 可用、`glmark2 Score 413 @1440x3200` |
| 桌面合成 | sway + swaybg 起来，`grim` 抓到完整 1440x3200 帧（曾抓到 SWAY 壁纸，颜色正常） |
| 按键 | `gpio-keys`(音量+) + `pmic_pwrkey`(电源) + `pmic_resin`(音量-)，PON 驱动需 `insmod qcom-pon.ko` |
| 截图/取色 | `grim` + `magick -format %[pixel:p{x,y}]` |

### 未解决：屏幕不刷新（唯一的真 blocker）

现象：面板初始化成功、背光可调、CRTC `enable=1`、`grim` 能抓到白/灰/绿色帧，
但**物理屏只显示 modeset 那一帧的纯色，之后不再刷新**（看不到文字、色块测试不变化）。

机制（上游代码为证）：
```
drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_cmd.c:381
    vsync_hz = dpu_kms_get_clk_rate(dpu_kms, "vsync");
    if (!vsync_hz) { DPU_DEBUG_CMDENC(...); return; }   ← 直接返回
arch/arm64/boot/dts/qcom/sm8350.dtsi 的 mdss clocks 只有
    iface / bus / nrt_bus / core —— 没有 "vsync"
```
→ `tearcheck` 永不使能 → 命令模式面板 read pointer 不前进 → `PP_DONE` 不来
→ 每次 commit 卡在等这个中断 → 只有第一帧下来。

试过的修法（都失败，别再重复）：

| 尝试 | 结果 |
|---|---|
| 设备树加 `qcom,te-source = "mdp_intf0"` | 整机挂死（无 USB/串口/WiFi） |
| 设备树给 mdss 加 `vsync` 时钟（`DISP_CC_MDSS_VSYNC_CLK`=44） | 整机挂死 |
| 面板改视频模式 `VIDEO｜VIDEO_BURST` | `dsi_err_worker: status=4` = `DSI_ERR_STATE_FIFO`，面板不接受 |
| 视频模式 + 关 DSC + 30Hz | `mipi_dsi_attach` 返回 `-ENOSPC`，attach 失败 |
| 面板 `mode_flags = MIPI_DSI_MODE_LPM`（照抄上游 cmd+DSC 面板 panel-lg-sw43408） | 厂商序列失效，`power_mode` 读回 `0x00`（面板根本没醒） |
| msm 里 tearcheck 拿不到 vsync 时钟时用 19.2MHz 兜底 | 已编译进 msm.ko，**未及验证**（用户决定回退） |

厂商侧事实（供后续参考）：Android 运行时 DTB 里
`qcom,mdss-dsi-te-pin-select = <0x01>`（TE 走 DSI 包回传，不是外部 GPIO）、
`te-dcs-command/te-check-enable/te-using-te-pin` 都开着。

### 未解决：触摸

`/dev/input/event*` 注册成功、驱动 probe 通过、两路电 `enabled=1`，
但读 `0x80` 等信息返回全 0；用 libgpiod 位操作（绕过 geni 控制器直接驱动 CS/CLK/MOSI/MISO）
读 `0x80/0x84/0xA8` 同样全 0 → **芯片没有应答，仍未真正上电/复位**。
注意：geni 读到的"回显"（`rx[n]==tx[n-1]`）是控制器行为，不是芯片行为。
工具：`/root/bitbang.c`（设备上已编译）。

### 这一轮踩到并已定论的坑（重要）

1. **`systemctl reboot` 在这台机器上不生效**（uptime 一直涨），必须 `echo b > /proc/sysrq-trigger`。
   后果：我曾以为"改完重启验证了"，实际一直在跑旧模块，白烧数轮。
2. **`tools/vpush.sh` 偶发推成 0 字节**，`insmod` 报 `Invalid parameters`。
   每次推送后必须核对字节数。
3. **背光映射是正向**：`值 = brightness*2047/255`，写 2047 = 最亮、写 0 = 关屏。
   面板是 AMOLED 自发光，深色内容看起来就"像背光没亮"，别再据此判断故障。
4. **`systemd-backlight@backlight:...` 会用保存值覆盖运行时亮度**（曾造成"闪白一下又黑"）。
5. `nixos-rebuild switch` 会重启 `getty@tty1`，旧 sway 占着 DRM master → 新 sway 起不来、
   只留孤儿 `swaybg/swayidle`（表现为黑屏）。处理：`pkill -f sway-unwrapped; pkill swaybg;
   systemctl restart getty@tty1`。
6. 该 nixpkgs 里**没有 `services.logind.settings`**，写它会令 rebuild 直接失败；
   要用 `services.logind.extraConfig`（`HandlePowerKey=ignore`）。否则电源键=关机。
7. `swayidle` 用 `dpms off` 关屏后无法正确恢复（花屏），改成只写背光 0。

### 存档

- git tag `screen-ok-v101`（屏幕首次正常出图时的源码状态）
- `~/mi11-work/known-good/boot-screen-ok-v101.img`（对应启动镜像）
- `~/mi11-work/known-good/ko-current.tgz`（当时的全部内核模块）
- 可启动镜像：`venus-boot-v107-touch-pwr.img`（当前已知最稳）

## 2026-10-26（续）· 屏幕刷新打通：tearcheck 兜底补丁生效

**结论：命令模式面板的"只有首帧、不刷新"已解决。**

根因链（每一步都有设备端输出为证）：

1. `sm8350.dtsi` 的 `mdss` 只提供 `iface/bus/nrt_bus/core` 四个时钟，
   没有 `vsync`。验证：`tr '\0' ' ' < /proc/device-tree/soc@0/display-subsystem@ae00000/clock-names`
   → `iface bus nrt_bus core`。
2. `drivers/gpu/drm/msm/disp/dpu1/dpu_encoder_phys_cmd.c` 的
   `dpu_encoder_phys_cmd_tearcheck_config()` 里
   `vsync_hz = dpu_kms_get_clk_rate(dpu_kms, "vsync"); if (!vsync_hz) return;`
   —— 拿到 0 就直接返回，tearcheck 永不使能 → 命令模式面板 read pointer 不前进
   → `PP_DONE` 不来 → 只有 modeset 那一帧下发。
3. 修法：在取不到 vsync 时钟时用 19.2MHz（dispcc vsync 源默认频率）兜底，
   让 `tc_cfg.vsync_count` 能算出来、tearcheck 得以编程。补丁位置同上函数的 `if (!vsync_hz)` 分支。

**验证方式（客观判据，不靠肉眼猜）**：
用 `swaymsg output * bg #RRGGBB solid_color` 依次刷 红/绿/蓝/白（每色 3 秒，5 轮），
用户确认**颜色在变**；同时 `dmesg` 里 `commit done / wait timeout` 计数为 0（提交没有超时）。
合成器侧用 `grim` 抓帧交叉核对像素值。

**注意：必须确认加载的是带补丁的模块**（我这次差点误判）。可靠的判据是 build-id：

```
cat /sys/module/msm/notes/.note.gnu.build-id | od -An -tx1     → 已加载模块的 build-id
readelf -n msm.ko | grep 'Build ID'                            → 文件里的 build-id
```

旧模块 `58834e31…`（8777856 字节）无补丁；新模块 `cc847674…`（8778024 字节）有补丁。

### 顺带澄清的两件事

- **触屏那轮改动并没有弄坏显示**。设备上跑的 DTB 是更早的那份
  （`qcom,te-source = "mdp_vsync_e"`、无 touch 节点），仓库 HEAD 里的
  `te-source = "mdp_intf0"` 和 `mdss` 加 `vsync` 时钟**从未进过设备**；
  `fts-spi-venus` 因为没有 DT 节点根本没绑定（`/dev/input` 只有 3 个按键设备）。
- **AMOLED 没有背光**：屏上内容全黑时看起来就是"背光没亮"。
  判断面板是否工作时，必须先把屏刷成纯白（`swaymsg output * bg #ffffff`），
  否则会把"黑色内容"误判成"面板没通电"。

### 已知遗留（下一步）

- `swayidle` 的 180 秒自动关背光会让人误以为故障，桌面改用 Plasma 后已移除该逻辑。
- 亮度映射方向未最终定论（代码现为正向：`brightness*2047/255`），待 0/128/255 三档实测。
- `git tag screen-ok-v101` 指向的提交里带着实验性 DTS（`te-source=mdp_intf0`、mdss vsync 时钟）
  与触屏代码，**不能当回滚点**，需要重新标注。

### 桌面环境（KDE Plasma 6）与背光实测

- 桌面改为 **Plasma 6 + SDDM 免登录**（与本机 NixOS 主机同款）。
  `services.desktopManager.plasma6.enable = true` + `services.displayManager.sddm`（wayland.enable）
  + `services.displayManager.autoLogin.user = "venus"`。
- ⚠️ **greetd 在这台机器上用不通**：`greetd` 要求 `default_session` 必须有 command
  （只写 `initial_session` 会直接 `default_session contains no command` 退出）；
  补上之后 KWin 仍然报
  `kwin_core: Failed to activate /org/freedesktop/login1/session/_N session`
  → 会话不是 logind 的普通用户会话。换 SDDM 一次成功，别再折腾 greetd。
- ⚠️ **踩过的自伤坑**：为了测 DRM 权限我跑过 `dd if=/dev/dri/card1`，
  而**读 DRM 设备会永久阻塞**，那三个 dd 进程把 `/dev/dri/card1` 的 fd 一直占着，
  于是 KWin 报 `Failed to open /dev/dri/card1 device (Device or resource busy)`，
  Plasma 反复起不来。杀掉它们、重启 display-manager 立刻正常。
  教训：测 DRM 权限只用 `open()+ioctl`，绝不要 `read()`。
- 显示模块加载服务改名 `venus-drm.service`（原 `venus-display.service` 被 cmdline 的
  `systemd.mask=` 挡住，改名后就能开机自动加载），并 `before = [ "display-manager.service" ]`，
  保证 Plasma 启动时 `/dev/dri/card1` 已存在。

**背光亮度实测（一次一变，纯白画面下判断）**：

```
255 → 亮；64 → 明显变暗（灰）；0 → 全黑
```
→ 映射是**正向**：`寄存器值 = brightness * 2047 / 255`，代码现实现正确。
AMOLED 深色内容下亮度变化几乎看不出来，测试必须先把屏刷成纯白
（`dd if=/dev/zero bs=1M count=20 | tr '\0' '\377' | dd of=/dev/fb0`）。默认亮度定为 128。

### 已知小瑕疵：加载图像时偶发一块花屏（会自己消失）

现象：开机/加载画面过程中，屏幕上出现一小块撕裂/花屏，画面稳定后自动消失。
`dmesg` 里没有任何 DSI/DPU 报错（`dsi_err|FIFO|underflow` 计数为 0）。

原因（代码依据）：主线 msm 的 DSI 驱动**完全不支持 DSI TE**——
`drivers/gpu/drm/msm/dsi/` 里没有任何 `te-pin-select` / `te-using-te-pin` / TE 中断处理代码。
所以我们只能靠"PP tearcheck + 假的 19.2MHz vsync"来 paced 命令模式面板：

```
tc_cfg.vsync_count = 19200000 / (vtotal(3280) * 120) = 48
```

这个值不是面板真实 TE 节奏，kickoff 偶尔会落在面板正在扫描的时刻 → 出现一块撕裂。
屏幕静止后不再 kickoff，所以花屏自己消失。

彻底修法需要给主线 DSI 补 TE 支持（解析 `qcom,mdss-dsi-te-*`、打开 TE 中断、
把 TE 事件接到 INTF vsync），是独立的驱动工作量；`te-source = "mdp_intf0"`
单改设备树没用（没有 TE 事件源），而且实测会把整机挂死。当前按"可接受的外观瑕疵"记录。

### 事故记录：一次改三样导致刷机后卡在启动早期

v110（触屏节点）一次性加了 `&spi11` 的 pinctrl 覆盖 + `ts_avdd` 稳压器 +
`&vreg_l3c_3p0` 强制 3.3V，刷入后设备卡在启动早期（WiFi/USB/COM3 全无，只有花屏）。
回滚镜像 `v111-display-safe`（只去掉这三样）后立刻恢复。

教训：设备树改动必须**一次只加一个节点**；L3C 是共享 PMIC 轨，强制改电压风险最高。
另外发现生成的 DTS 本来就带 `&spi11 { status = "okay" }`（来自 star 参考），
所以 spi11 控制器此前一直是开着的，卡死不是它本身。

### 触屏进展与真正卡点（2026-10-26 晚）

**已排除硬件链路问题**（都有设备端输出为证）：

- 引脚复用正确：Android 运行时 DTB 里 `spi@a8c000` 的 pinctrl 指向 `qupv3_se11_spi_active`，
  pins = `gpio48..51`、`function = "qup11"`，与我们 DTS 里的 `qup_spi11_default` 完全一致。
- 供电已开：`regulator_summary` 显示 `vreg_l2c_1p8`（1800mV，vdd）、
  `vreg_l3c_3p0`（3008mV）、`ts_avdd`（3300mV，GPIO132 开关）全部 `enabled=1`。
- 驱动绑定成功，`/dev/input/event3` 已创建；`venus-fts: vdd enable rc=0 / avdd enable rc=0`、
  `supply[0] vdd enabled=1 / supply[1] avdd enabled=1`。
- CS 处理正确：命令与数据在同一个 `spi_message` 内（不会中途抬 CS）。

**真正卡点：我们这套驱动的 SPI 命令帧格式是错的。**
从厂商驱动（Evolution-X-Devices/kernel_xiaomi_venus，
`drivers/input/touchscreen/fts_spi/fts_lib/ftsIO.c`）读到的真实协议：

- 写：`fts_write(cmd, cmdLength)` —— **命令是 3~6 字节的帧**，
  例如 `{0xa0, 0x03, 0x00}`、`{0xfa, 0x20, 0x00, 0x00, 0x29, 0x02}`、`{0xC0, 0x00, 0x00, 0xF9}`。
- 读：`fts_write_read(cmd, cmdLen, out, outLen)` —— 同一个 spi_message 内两个 transfer：
  先写 cmdLength 字节命令，再读 byteToRead 字节数据；
  **读的第一字节没有"回显占位"**（`transfer[0].rx_buf = NULL`），
  所以我们驱动里"多读 1 字节丢掉"的假设也是错的，真实数据会被整体错位。

结论：芯片不是没上电，是听不懂我们发的单字节命令，所以全部回 0
（`chip_id=0x0000`，而且 `[a8 00 00 00 …]` 的首字节是 MOSI 回读，不是芯片应答）。

下一步是移植厂商 `fts_lib`（ftsIO/ftsCore/ftsTest/ftsFlash）或至少把命令帧格式与初始化序列照抄过来，
属于驱动移植工作量，不再是设备树/配置问题。

### 本轮设备树改动（v112 / v113，均已刷入且系统正常）

- v112：只加 `touchscreen@0` 子节点（`vdd = L2C`、`avdd = L3C`）→ 系统正常，驱动绑定，读回全 0
- v113：再加 `ts_avdd`（GPIO132 负载开关，`vin = L3C`），**不动 L3C 电压**→ 系统正常，读回仍全 0
- 两次都没有出现 v110 那种"整机卡死"，说明 v110 的挂机是 `&vreg_l3c_3p0` 强制 3.3V 那一项（而不是触摸节点本身）
