# 同款（SM8350 / venus）在别处的状态

目的：确认哪些能力在别的项目里已经跑通，避免重复试错。

## postmarketOS（上游社区）

`wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_888_(SM8350)` 的状态表（2026-11 抓取）：

| 项 | 状态 |
|---|---|
| 内核包 | `postmarketos-qcom-sm8350`（`testing`） |
| CPU / 存储 / pinctrl | Y |
| **USB** | **P（部分可用）** |
| **WiFi** | **空（未标注可用）** |
| 显示 / GPU / 音频 / 视频 / 热 / 蓝牙 /  modem / 摄像头 | 空或未标注 |
| 备注 | "There is partial support for this device already in mainline, with more being worked on." |

`sm8350-mainline/linux`（社区主线内核仓库，GitLab，默认分支 `dev`）的
`arch/arm64/boot/dts/qcom/` 里**没有 venus 的 DTS**（只有 oneplus/其他 sm8350 机型），
`sm8350-xiaomi-venus.dts` 404。也就是说 venus 的主线移植在本仓库之外没有现成实现。

## 对我们的意义

1. **WiFi 不是我们独有的难题**：SM8350 mainline 的 WiFi 在上游状态表里就是空白，
   社区尚未跑通。我们的 `ath11k` RDDM 崩溃大概率属于同一类未解问题，
   不应期待"配置对齐就好"。
2. **USB 是 P（部分可用）**：这与我们实测一致 —— gadget 能建、Windows 能看到 COM3，
   但在 `switch_root` 这类控制器状态切换时会掉，且需要重新插拔才能重新枚举。
   所以 USB 串口的正确定位是"部分可用"，要把可用性做到稳定需要我们自己解决
   （这也是 M1 里程碑之后要做的 M2）。
3. 我们的 venus DTS / 补丁集是**本仓库独有的资产**（含 display、触摸、panel、
   userspace-consumer、ath11k WCN6851 支持等），无法从上游直接抄。

## 待补充

- `postmarketos-qcom-sm8350` 的 APKBUILD（内核版本、kconfig 片段、补丁集）尚未取到，
  后续用 GitLab API 在 `main/` 或 `device/` 下按名称检索。
- 社区 Matrix（`#sm8350-mainlining:matrix.org`）关于 ath11k / WCN6855 的结论未取。
