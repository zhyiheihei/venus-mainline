# venus 主线适配参考清单

原则：**先找别人已经跑通的同芯片方案，再动手**。下面是本轮实际查阅过、并且直接改变了我们做法的资料。
每条都标注了「对我们有什么用」，避免收集一堆没用上的链接。

## 一、直接同族设备（小米 SM8350，最有价值）

| 资料 | 位置 | 用处 |
| --- | --- | --- |
| Xiaomi Mi 11 Ultra（star）主线 DTS，1249 行，作者已实测启动 | https://patchew.org/linux/20231021-sakuramist-mi11u-v2-0-fa82c91ecaf0@gmail.com/ （mbox 可下载，本机留档 `/tmp/star.mbox`、`/tmp/sm8350-xiaomi-star.dts`） | star 与 venus 同平台（lahaina）。**给出了完整的打包+刷机配方**，见下节。UFS/USB 节点取值与我们一致，可直接对照 |
| 同一系列的 v1 | https://patchew.org/linux/20230806-xiaomi-star-v1-0-0c384e8b5737@gmail.com/ | 看 v1→v2 改了什么（v2 补了 UFS host supply、framebuffer 节点命名） |
| LineageOS venus 设备树（Android 侧） | https://wiki.lineageos.org/devices/venus | 确认硬件清单（6/8/12GB、1440x3200、SM8350） |
| venus 下游内核/设备树 | https://github.com/soumya19x/android_device_xiaomi_venus 、https://github.com/pix106/android_kernel_xiaomi_sm8350 | 硬件真相来源（GPIO、稳压器、面板参数） |
| **本机 Android 运行中的 DTB** | `adb shell su -c "cat /sys/firmware/fdt"`（本机留档 `~/mi11-work/images/fdt_android.dtb`） | 最权威：内存映射、`qcom,board-id=<0x10008 0x0>`、`msm-id`、splash 区域、initrd 地址全在里面 |

## 二、通用方法（决定我们之前为什么一直失败）

| 资料 | 位置 | 用处 |
| --- | --- | --- |
| Linaro《Booting the Mainline Linux Kernel on Qualcomm Devices》 | https://www.linaro.org/blog/let-s-boot-the-mainline-linux-kernel-on-qualcomm-devices | 关键两句：① 要先搞定 `qcom,board-id` / `qcom,msm-id` 和 **dtbo**；② **dtbo 分区要写 0 而不是 erase**，有些 bootloader 在分区被 erase 后会直接失败 |
| FOSDEM 2022《Porting mainline Linux to mobile phones》 | https://archive.fosdem.org/2022/schedule/event/mobile_kernel_mainline/attachments/slides/4856/export/events/attachments/mobile_kernel_mainline/slides/4856/Porting_mainline_Linux_to_mobile_phones.pdf | 同一套流程的幻灯片版；强调「没有 UART 就得靠猜」——所以观测通道要自己造 |
| Qualcomm mainline status: SM8350 | https://linux-msm.github.io/mainline-status/soc/sm8350 | 官方支持矩阵：UFS 自 5.13、USB peripheral 自 5.13、DSI 6.3、GPU 6.3。说明 M1/M2 完全在上游能力范围内 |
| sm8350-mainline 内核仓 | https://gitlab.com/sm8350-mainline/linux （分支 `nia/sm8350/bringup`、`dev` 等） | 同芯片社区仓，可按需看他们为手机补的补丁 |

## 三、同类机型（不同芯片，但方法通用）

| 资料 | 位置 | 用处 |
| --- | --- | --- |
| Sony Xperia 5 II（pdx206, SM8250）完整移植笔记 | https://github.com/terminal-index/pdx206-mainline | 失败复盘的教科书：regulator_late_cleanup 关电源轨、PMIC 看门狗 32s、hybrid DTB pool、RNDIS 调试网 |
| Project-SunUEFI（SM8750 平板） | https://github.com/slwyts/Project-SunUEFI | 合体 BOOT（改内核入口分支 + 追加 payload）思路；现阶段只用其「不依赖 ABL 支持 UEFI」的观察 |
| 上游参考 DTS：`sm8350-mtp.dts`、`sm8350-hdk.dts`、`sm8350-sony-xperia-sagami*` | 内核树 `arch/arm64/boot/dts/qcom/` | UFS/USB 节点的标准写法（我们的 venus.dts 就是从这里裁的） |

## 四、已被 star 作者实证的打包 + 刷机配方（我们的下一步照此执行）

```sh
# 1. 内核 + DTB 拼在一起（Qualcomm 传统做法，ABL 认这个）
cat arch/arm64/boot/Image.gz arch/arm64/boot/dts/qcom/sm8350-xiaomi-<device>.dtb > .Image.gz-dtb

# 2. header_version 1（不是 3/4！v3+ 会丢 dtb），Kona/lahaina 偏移
mkbootimg --kernel .Image.gz-dtb --ramdisk some_initrd.img \
  --pagesize 4096 --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
  --tags_offset 0x100 --dtb_offset 0x1f00000 --header_version 1 \
  --os_version 14.0.0 --os_patch_level 2099-12 \
  --cmdline "..." -o boot.img

# 3. 刷到 slot b，并把 dtbo_b 清掉（Linaro 建议写 0，而不是 erase）
fastboot flash boot_b boot.img
fastboot flash vbmeta_b vbmeta.img            # 需要关掉校验时
fastboot flash vbmeta_system_b vbmeta_system.img
fastboot set_active b
# dtbo：dd if=/dev/zero 写 1 个 block 进 dtbo_b，或 fastboot erase dtbo_b
fastboot reboot
```

**推论（解释了我们 10 月 24 日一整天的失败）**：
venus 的 base DTB 来自 **dtbo 分区**（我们实测 `dtbo.img` 偏移 ~13552199 有完整 venus DTB，Android 的
bootargs 里也确有 `androidboot.dtb_idx=4`）。只要 dtbo 还在，ABL 就永远用它的 DTB，我们塞进
boot/vendor_boot 的任何 DTB 都不会生效 —— 所以之前所有「换 DTB」的尝试其实都在原地打转。

## 五、待补的参考（下一步继续收集）

- postmarketOS 是否有 venus 设备包（`device/testing/xiaomi-venus`）
- Ubuntu Touch / Droidian 的 venus 端口
- 其他 lahaina 机型（小米 11 Pro `mars`、11 Ultra `star`、Redmi K40 Pro `haydn`）的主线尝试
- `qbootctl`（A/B 槽位切换工具）在小米设备上的坑
- msm8998-mainline / sm8250-mainline 的「dtbo 置零」实操记录

## 六、小米官方内核（厂商内核）——star 作者真正用的参考源

小米官方 GitHub：`MiCode/Xiaomi_Kernel_OpenSource`，venus 对应分支 **`venus-r-oss`**（Android R）。

```sh
git clone --depth 1 --filter=blob:none --sparse --branch venus-r-oss \
  https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git venus-oss
```

两个结论：

1. **官方投放里没有板级 DTS**（`arch/arm64/boot/dts/vendor` 不存在，0 个文件）—— 小米把 board DTS 摘掉了，
   所以"从官方仓直接拿 venus.dtsi"这条路走不通。
2. **但官方投放里有 venus 的内核配置**：`arch/arm64/configs/vendor/venus_GKI.config`、
   `venus_QGKI.config`。将来做 NixOS 内核配置时可拿它当对照表（哪些驱动 venus 真的要）。

板级 DTS 的实际来源是 LineageOS 的内核 fork（基于小米投放补全了 vendor DTS）：

```
https://raw.githubusercontent.com/LineageOS/android_kernel_xiaomi_sm8350/lineage-22.1/arch/arm64/boot/dts/vendor/qcom/<file>
```

本机已取到的文件（`~/mi11-work/venus-vendor-dts/`）：

| 文件 | 用途 |
| --- | --- |
| `venus-sm8350.dtsi` | venus 板级主文件（18415 字节） |
| `venus-pinctrl.dtsi`、`venus-audio-overlay.dtsi`、`venus-sm8350-overlay.dts` | venus 引脚/音频/覆盖 |
| `xiaomi-sm8350-common.dtsi` | venus/mars/star 共用的板级数据（UFS/USB/NFC/充电都在这里） |
| `lahaina-pmic-overlay.dtsi` | PM8350/B/C、PMK8350、PMR735A 全部稳压器定义 |
| `star-sm8350.dtsi`、`mars-sm8350.dtsi` | 对照用（venus vs star 差 552 行，venus vs mars 差 438 行） |

### 已读出的 venus 专属值（star 的主线 DTS 里没有）

**UFS（`&ufshc_mem`）**
```dts
vdd-hba-supply = <&gcc_ufs_phy_gdsc>;   /* 不是 LDO，是 GCC 的 PHY GDSC */
vdd-hba-fixed-regulator;
vcc-supply = <&pm8350_l7>;  vcc-voltage-level = <2504000 2950000>;
vccq-supply = <&pm8350_l9>; qcom,vddp-ref-clk-supply = <&pm8350_l9>;
qcom,vccq-parent-supply = <&pm8350_s12>;
spm-level = <3>;
```
**UFS PHY（`&ufsphy_mem`）**：`qcom,ufs-phy-qmp-v4-lahaina`；`vdda-phy = pm8350_l5`（`vdda-phy-always-on`）；`vdda-pll = pm8350_l6`。

**USB**：venus 实际用的是 **usb0（a600000.dwc3，即主线 `usb_1`）**，`usb2_phy0 + usb_nop_phy`，
`maximum-speed = "high-speed"`；`usb1` / `usb_qmp_phy` / `usb_qmp_dp_phy` 全部 disabled。
另外 venus 有 **板级 USB2 PHY 调参**（主线 `usb_1_hsphy` 同名属性）：
```dts
&usb2_phy0 {
	qcom,param-override-seq = <0xc6 0x6c  0x0f 0x70  0x00 0x74>;
};
```

## 七、Evolution X（我们机器上正在跑的系统）也是全开源的

| 仓库 | 分支 | 内容 |
| --- | --- | --- |
| `Evolution-X-Devices/device_xiaomi_venus` | `cnb` | venus 设备树（BoardConfig、fstab、overlay） |
| `Evolution-X-Devices/device_xiaomi_sm8350-common` | `cnb` | venus/mars/star 共用板级配置（`BoardConfigCommon.mk` 等） |
| `Evolution-X-Devices/kernel_xiaomi_venus` | `cnb` | 内核源码，**含 vendor 板级 DTS**（`arch/arm64/boot/dts/vendor/qcom/`，958 个文件） |
| `Evolution-X-Devices/kernel_xiaomi_sm8350` | `udc` | 同平台内核（sm8350） |
| `Evolution-X-Devices/vendor_xiaomi_venus-old`、`vendor_xiaomi_sm8350-common` | `bka`/`cnb` | 厂商 blob 清单 |

EvoX 的 vendor DTS 和 LineageOS fork 完全一致（`venus-sm8350.dtsi` 都是 18415 字节、
`xiaomi-sm8350-common.dtsi` 7767 字节），也就是**我们手机上真正在跑的那份**。

### 从 `BoardConfigCommon.mk` 读到的关键事实

```
BOARD_BOOT_HEADER_VERSION := 3          # 原生 boot.img 是 v3 → 没有 dtb 段
BOARD_KERNEL_SEPARATED_DTBO := true     # DTBO 是独立分区镜像
BOARD_INCLUDE_DTB_IN_BOOTIMG := true    # SoC 的 dtb pool 放进 vendor_boot
BOARD_KERNEL_BASE := 0x00000000
BOARD_KERNEL_PAGESIZE := 4096
TARGET_KERNEL_CONFIG := vendor/lahaina-qgki_defconfig vendor/debugfs.config vendor/xiaomi_QGKI.config
BOARD_KERNEL_CMDLINE += androidboot.usbcontroller=a600000.dwc3   # 确认 USB 控制器是 a600000
```

### DTBO 的真实构造（决定性）

```
arch/arm64/boot/dts/vendor/qcom/venus-sm8350-overlay.dts   (只有 10 行)
  /dts-v1/; /plugin/;
  #include "venus-sm8350.dtsi"
  / { model = "Venus based on Qualcomm Technologies, Inc SM8350";
      compatible = "qcom,lahaina-mtp", "qcom,lahaina", "qcom,mtp";
      qcom,board-id = <0x10008 0>;  xiaomi,board-id = <0x3 0>; };

Makefile:  venus-sm8350-overlay.dtbo-base := lahaina.dtb
```

即：**我们手机上运行的 DTB = `lahaina.dtb`（SoC 基座）+ `venus-sm8350-overlay.dtbo`（板级覆盖层）**，
由 ABL 按 `qcom,board-id = <0x10008 0>` 选中并合并。这与我们从 `/sys/firmware/fdt` 读到的
model/compatible/board-id 完全吻合。

推论：主线内核不吃 dtbo overlay 机制，所以想让我们的 DTB 生效只有两条路：
1. **star 配方**（已实证）：`header_version 1` + `Image.gz + dtb` 拼接 + 清空 dtbo_b，让 ABL 用 boot 镜像里的 DTB；
2. 自己造一个 dtbo_b（把我们的完整 DTB 当"overlay"塞进去）—— 不推荐，ABL 会按 board-id 挑选且可能校验表结构。

## 2026-10-27 · 查证：同型号/同芯片有没有人把喇叭做通？

- **主线**：`grep -r 'TERTIARY_TDM_RX_0' arch/arm64/boot/dts/qcom/` 只有我们自己的 venus.dts。
  即主线没有任何设备用过 Q6AFE 的 TDM 路径（MI2S 才有大量用户）。
- **CS35L41**：主线的 cs35l41 用户只有索尼机型（sm8250-edo / sm8350-sagami / sm8450-nagara），
  它们 DTS 里有功放节点，但**没有声卡 dai-link**，等于没接。
- **同芯片主线机型**（sagami / mtp / hdk / star）：音频全部未接（star 也一样）。
- **上游 TDM 支持的时间线**：Qualcomm 的 Prasad Kumpatla 在 2026-06 才提交
  «ASoC: qcom: add AudioReach TDM backend support»（AudioReach/Q6APM 路径），
  我们这棵 7.2.6 里还没有（q6apm-lpass-dais.c 无 TDM）。而本机 ADSP 固件只支持老的
  Q6AFE/APR 路径 → 只能自己把厂商的 TDM 组设备支持移植进 mainline q6afe（已完成）。
- **厂商侧**（Xiaomi OSS / Evolution-X 内核 techpack/audio）：TDM 走"组设备"
  `AFE_MODULE_GROUP_DEVICE` + `AFE_PARAM_ID_GROUP_DEVICE_TDM_CONFIG`，
  组 id = 端口 id + 0x100，`num_channels = nslots_per_frame`、`bit_width = slot_width`，
  DT 里 `qcom,msm-cpudai-tdm-clk-rate = 0x177000`（1.536MHz）。
