# venus 配置审核：与主线 sm8350 的逐项对照

审核对象：`kernel/venus/sm8350-xiaomi-venus.dts` + 自建内核配置。
参照物：主线同 SoC 的 `sm8350.dtsi` / `sm8350-hdk.dts` / `sm8350-mtp.dts` /
`sm8350-sony-xperia-sagami-pdx215.dts` / `sm8350-microsoft-surface-duo2.dts`，
以及**手机真实设备树**（EvoX `vendor_boot` 的 dtb#4 = Lahaina 基础 DT，
`dtbo` #46 = Venus overlay，反编译件在 `~/.cache/venus-dt/`）。

判定分四类：
- **A 与主线一致** —— 照上游写的，不用动。
- **B 设备专有** —— 主线没有这块板，必须写，值取自厂商 DT。
- **C 我们的 workaround** —— 非标准但有必要，需注明原因与风险。
- **D 缺陷** —— 该修（本次已修的在最后一节）。

---

## 1. reserved-memory（最容易致命的一层）

主线 `sm8350.dtsi` 写的是**通用参考板**的布局，和 venus 实际布局差很多。
逐地址比对（vendor = 手机真实基础 DT，27 条里我们最终 27 条）：

| 区域 | vendor | 主线 dtsi | 我们 | 判定 |
|---|---|---|---|---|
| hyp 0x80000000 | 6144K | 6144K | 6144K | A |
| xbl_aop 0x80600000 | **2432K** | 0x80700000 +1408K | 2432K | D 已修（主线少 reserve 1MB）|
| cmd_db 0x80860000 | 128K | 128K | 128K | A |
| xbl_uefi_log 0x80880000 | 80K | 80K | 80K | A |
| smem 0x80900000 | 2048K | 2048K | 2048K | A |
| cpucp_fw 0x80b00000 | 1024K | 1024K | 1024K | A |
| cdsp_secure_heap 0x80c00000 | 71680K | 71680K | 71680K | A |
| pil_camera 0x85200000 | 5120K | 5120K | 5120K | A |
| pil_video 0x85700000 | 5120K | 5120K | 5120K | A |
| pil_cvp 0x85c00000 | 5120K | 5120K | 5120K | A |
| pil_adsp 0x86100000 | **58368K** | 33792K | 58368K | D 已修 |
| pil_slpi 0x89a00000 | **48128K** | 0x89700000 +30720K | 48128K | D 已修 |
| pil_cdsp 0x8c900000 | **30720K** | 0x88200000 +21504K | 30720K | D 已修 |
| pil_ipa_fw/gsi/gpu 0x8e7xxxxx | 64K/40K/8K | 0x8b5xxxxx | 与 vendor 同址 | D 已修 |
| pil_spss 0x8e800000 | 1024K | 0x8b600000 | 与 vendor 同址 | D 已修 |
| modem 0x8f000000 | 262144K | 0x8b800000 | 与 vendor 同址 | D 已修 |
| removed_mem 0xd8800000 | **163840K** | 106496K | 163840K | D 已修 |
| rmtfs | vendor 是 uio 动态分配 | 0x9b800000 +2560K | **0xd6a00000 +3072K（我们自选）** | C |
| ramoops 0xa9000000 | 无 | 无 | **2048K（我们自选）** | C |
| splash 0xea600000 | overlay 里 35840K | 无 | 与 vendor 同 | D 已修 |
| dfps_data 0xec900000 | overlay 里 1024K | 无 | 与 vendor 同 | D 已修 |

`memory` 节点是全零占位（`reg = <0 0 0 0>`），由 ABL 按实际 DDR 注入 —— 这条是 A（抄手机真 DT），
之前写死旧 8GB 机布局导致卡米标，已修。

**C 类的两只**：`rmtfs` 地址是我们挑的空闲区（主线那个地址在 vendor 的 pil_slpi 范围内，直接沿用会踩），
`ramoops` 只用于 pstore（panic 时存日志），都不与 vendor 任何保留区重叠。

---

## 2. 外设节点（与主线 HDK 逐项对照）

| 项目 | 主线 HDK | 我们 | 判定 |
|---|---|---|---|
| `&pcie0` | perst=gpio94 (LOW)、wake=gpio96 (HIGH)、pinctrl `pcie0_default_state` | 完全相同 | A |
| `&pcie0_phy` | vdda-phy=L5B 0.88V、vdda-pll=L6B 1.2V | 完全相同 | A |
| `pcie1` | HDK 也开了（给 modem）| 我们关（不用 modem）| B |
| `&mpss` | HDK okay | 我们 disabled | B（不做基带）|
| `&usb_1` / `dwc3` | USB2 only，`select-utmi-as-pipe-clk` | 同 | A |
| `&usb_1_dwc3` | HDK: `dr_mode="otg"` + `usb-role-switch` | 同 + `role-switch-default-mode="peripheral"` | B（多这一项是为了保住 ACM 串口）|
| `pmic-glink` connector | HDK `connector@0 { usb-c-connector; dual/dual; port@0 → usb_1_dwc3_hs }` | 逐字相同 | A |
| `&ufs_mem_hc` / phy | 主线值 | 同 | A |
| `&pcie0` 重训 | 主线不做 | 我们补 `pcie-qcom` 的 `remove` 回调（否则重新 probe 会 `-ENOSPC`）| C（文档化）|
| `&tlmm gpio-reserved-ranges` | 主线无 | 我们 `<52 8>` | B（厂商 DT）|

---

## 3. WiFi / BT 供电（本项目最"不标准"的一块）

主线板子（HDK/sagami）把 WiFi 电源放在 board 级 `regulator-always-on`，芯片使能脚直接配 pinctrl。
我们不能那样做——**实测 3 次写进设备树就开不了机**（docs/porting-notes 有记录）。当前做法：

```
五路电源：wifi_dig/io/rfa1/rfa2/aon  = regulator-output 包 PMIC 的 S10B/S11B/S12B/S1C/PMR735A-S2
使能脚：  wlan_en(gpio64, active-high) = regulator-fixed + 自己的 pinctrl
          bt_en(gpio65)              = wlan_en 的兄弟，由 hci_qca 的 enable-gpios 驱动
用户态：  /etc/venus-wifi-setup 按 vendor 时序 echo voltage/state
```

**判定 C**，但有两个必要条件，缺一个就"WiFi 全哑、PCIe 端点不枚举"：

1. 内核补丁 `drivers/regulator/userspace-consumer.c`：允许非独占 `regulator_get`、容忍
   `is_enabled()` 返回负值。**没有它**，五路 `regulator-output` 全部
   `-EBUSY: Failed to get supplies` 探测失败，用户态 echo 什么都不会发生。
   → 已写进 `tools/apply-kernel-patches.sh` 并加了自检（以前补丁代码丢了，只剩注释，
   所以每次重建内核 = WiFi 必挂，这是我踩坑两次的真正原因）。
2. **gpio64 的 pinctrl**。厂商 DT 有 `cnss_pins/cnss_wlan_en_active`
   （function=gpio、drive-strength=16mA、bias-pull-up）；主线没有，我们以前也没有，
   pad 只能继承 bootloader 留下的状态——运气好能用，运气不好 WLAN_EN 驱不动。
   → 本次已补（见下）。

---

## 4. 内核配置（与设备基线 /proc/config.gz 对比）

自建内核的基线**必须**是设备上正在跑的那份 `/proc/config.gz`（`tools/build-kernel.sh` 已强制）。
用 `defconfig` 重建会静默丢掉 `panel-xiaomi-venus-k2`、`fts-spi-venus` 等本地驱动，
产出的内核能启动但黑屏——这条也踩过。

本地补丁清单（`tools/apply-kernel-patches.sh`，全部幂等 + 末尾自检）：

| 补丁 | 作用 | 缺了会怎样 |
|---|---|---|
| 面板驱动 + Kconfig/Makefile | K2 AMOLED | 黑屏 |
| 触摸驱动 `fts-spi-venus.c` | ST FTS over SPI | 无触摸 |
| `pcie-qcom` 去 `suppress_bind_attrs` + 加 `remove` | 允许运行时重训链路 | WiFi 永远起不来（`-ENOSPC`）|
| `userspace-consumer` 非独占/容忍 is_enabled | WiFi 五路电 | 五路电全 `-EBUSY`，WiFi 全哑 |
| `dpu_encoder_phys_cmd` vsync 四舍五入 | 减小撕裂 | 画面轻微漂移 |
| `qcom_battmgr` 屏蔽 TTF/TTE/MODEL_NAME | 免 dmesg 刷屏 | 每秒一条错误日志 |

与上游 `arch/arm64/configs/defconfig` 的差异不做逐条比较（那份是"所有 ARM64 平台"的合集，
7000+ 项里绝大多数是别家的板子）。真正有意义的是上面这份**本地补丁表**和
"PCIe/PHY/ATH11K/UFS/USB/SPMI/RPMh 等关键驱动都是 `=y`"这一条 —— 已核对与设备基线一致。

---

## 5. 本次改了什么（D 类）

1. **补回 `userspace-consumer` 补丁**并加入 `apply-kernel-patches.sh`，脚本末尾增加自检：
   六处补丁任一没落位就 `exit 1`，防止再出现"补丁静默丢失"。
2. **补 `wlan_en`(gpio64) / `bt_en`(gpio65) 的 pinctrl**，值与厂商 DT 对齐：
   - wlan_en：`function=gpio`、`drive-strength=16`、`bias-pull-up`
   - bt_en：`function=gpio`、`drive-strength=2`、`bias-pull-down`

   实测（工作版内核 + 本 DTB）：

   ```
   /sys/kernel/debug/pinctrl/f100000.pinctrl/pinmux-pins:
     pin 64 (GPIO_64): device regulator-wlan-en function gpio group gpio64
   ```

   即该脚现在由我们的 regulator 独占并正确 mux 成 GPIO；WiFi 起来、拿到 192.168.0.150。

3. `tools/build-kernel.sh`：把"基线取设备 `/proc/config.gz`""先打补丁再编译""产物交给
   `tools/pack-kernel.sh`"固化成一条命令，避免手工步骤漏项。

---

## 6. 遗留

- 重建内核后 PCIe 端点不枚举的问题，本次已消除两个已知必要条件（regulator 补丁、gpio64 pinctrl），
  但**尚未用重建的内核验证**。验证方式：把 `boot-otg2.img` 那一类镜像刷到 boot_b，
  看 `dmesg | grep -E "link up|17cb:1103"`。若仍失败，需要串口（数据线目前两边都枚举不到设备）。
- USB OTG（接键鼠）的 DTS/配置已按 `sm8350-hdk.dts` 就绪，等上面这条通过后再落。
- 红外发射已按用户决定放弃；vendor overlay 里的 `ir-spi@0` 取证留在 `~/.cache/venus-dt/`。
