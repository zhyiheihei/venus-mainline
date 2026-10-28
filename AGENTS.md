# venus-mainline 项目约定

> ## ⛔ 项目已终止（2026-10-28）
>
> 设备在**音频适配阶段**刷入 v197（内核配置 + DTB + initrd 三改齐上、无回退槽）后
> 整机无响应；EDL（9008）救援确认 **PBL→XBL→ABL 引导链不启动**，boot_a/b、abl、
> vbmeta、misc 内容完好（哈希级证据），持久损伤定位在 XBL 阶段、成因未定。
> 本项目**终止更新**：不再刷机、不再继续适配。仓库保留全部开发资产
> （内核 / DTS / NixOS 配置 / 工具链 / 文档），供同类 SM8350 机型移植参考。
> 硬件支持情况见下方清单；事故全过程见 docs/porting-notes.md 2026-10-28 节。

- 本项目独立于 nixos-config 主仓,专门做小米11(venus)主线 Linux 适配,最终产出 NixOS
- **新 agent 接手先读 docs/HANDOFF.md（设备现状/已证事实/坑位清单/下一步）,再读 docs/porting-notes.md**
- 刷机红线:绝不 flash xbl*/xbl_config*/abl/tz/hyp/keymaster/devcfg/cmnlib*/qupfw/imagefv/persist/modemst1/2 与分区表
- **venus 的 ABL 不支持 `fastboot boot` 内存引导(静默不执行)**:日常验证只能 `fastboot flash boot_a X && set_active a && continue`,且**必须在新鲜 fastboot 会话里单发**(同会话第二次起几乎必 Load Error);验证只烧一次,失败先取 misc 日志再重试
- 刷机操作走 Windows 主机(ssh <windows-user>@<LAN_WINDOWS_IP>),NixOS 侧 fastboot 大传输必断;**每次让用户操作前先声明需要的手机状态**
- ROM 包(fastboot 完整包/OTA zip)与官方镜像常备 ~/mi11-work/,官方恢复路径已在 2026-10-23 实证(EvoX First Time Install,见 porting-notes)
- 厂商固件文件不进 git,只落本机 `/lib/firmware`
- flake 用 flake-parts;NixOS 配置保持 headless 最小集,图形栈等亮屏后再说
- 每个 milestone 完成后在 docs/porting-notes.md 追加日志,引用实际输出为证;**日志读取走 misc 分区通道(init 每 15s 写 dmesg 到 misc 偏移 4KB 起),recovery sideload 读出**
- git 提交用 conventional commits,中文说明原因

## 仓库结构（2026-10-25 更新）

```
kernel/venus/
  sm8350-xiaomi-venus.dts     # venus 主线设备树（由 tools/gen-venus-dts.py 从 star 参考生成）
  star-reference.dts          # Mi 11 Ultra 主线 DTS 存档（参考源）
  initramfs/init              # initramfs 的 /init（双系统引导：NixOS 优先，Alpine 兜底）
nixos/
  configuration.nix           # NixOS 配置（WiFi/SSH/串口/固件/venus 专有 systemd 服务）
  firmware/                   # 厂商固件（**不进 git**，用 tools/extract-firmware.sh 生成）
tools/
  gen-venus-dts.py            # 从 star 参考生成 venus DTS（--stage 1|2 [--no-fb]）
  extract-firmware.sh         # 从本机 ~/mi11-work 提取固件到 nixos/firmware/
  vcmd.sh / vsh.sh            # 通过 WiFi ssh 在手机上执行/交互
  vpush.sh / vpull.sh         # tar over ssh 传文件（dropbear 没有 sftp，别用新 scp）
  wserial.sh                  # 走 Windows COM3 的命令通道（手机跑我们内核时的串口 shell）
  serial.sh / serial-login.sh / serial-put.sh   # 走本机 /dev/ttyACM0
  deploy-nixos.sh             # 推配置 + nixos-rebuild switch
  update-kernel.sh            # 换内核（dd 到 boot_b）
docs/porting-notes.md         # 里程碑日志（每条结论附实测输出）
docs/references.md            # 参考来源分类整理
```

## 硬件支持情况（终止时点，均为实机验证过的最后已知良好状态）

| 部件 | 状态 | 说明 |
|---|---|---|
| 内核/系统 | ✅ | 主线 Linux 7.2.6（自建）+ NixOS 25.05，systemd running |
| UFS 存储 | ✅ | sda(34 分区)/sde(71 分区)，ext4 rootfs（sda29 Alpine / sda34 NixOS） |
| USB | ✅ | gadget ACM 串口（18d1:4ee1 VENUS-M1）；NCM 已移除 |
| WiFi | ✅ | QCA6490（WCN6851 hw1.1）ath11k + WCN6851 补丁；开机自动上电→PCIe 重训→联网 <LAN_PHONE_IP> |
| 蓝牙 | ✅ | UART SE18 + hpbtfw10.tlv + arcata 式绑定；BlueZ 可见可上电可扫描，keepalive 自愈 |
| 显示 | ✅ | panel-xiaomi-venus-k2（厂商 DTB 解出 73 条初始化 + 同源 PPS）+ DSC；真 TE（TLMM82 复用 mdp_vsync，te-source=mdp_vsync_p）；120Hz；亮度 0x51 正向 |
| 桌面 | ✅ | KDE Plasma 6 + SDDM 免登录；HiDPI 200%、横屏旋转 |
| 触屏 | ✅ | fts-spi-venus（照搬厂商 fts_lib 时序）中断驱动，开机自动加载 |
| GPU | ✅ | Adreno 660：freedreno FD660 + turnip，glmark2 413/949，devfreq 正常 |
| 电池/电量 | ✅ | ADSP remoteproc + pmic_glink + qcom_battmgr（官方路径），电量/电压/状态可读 |
| 按键 | ✅ | gpio-keys 三键（电源键 logind ignore） |
| 调试通道 | ✅ | WiFi ssh（tar over ssh）+ USB ACM + Windows COM3 三路 |
| 传感器/RTC | ✅ | 热、RTC(SPMI SDAM)、I2C 等 |
| **音频（喇叭/麦克风/通话）** | ❌ | 推进至：TDM 组 ABI 破解、AFE 开流、功放 PWR_CTRL1 上电、MI2S2 引脚复用；**仍无声**（DSP 不消费数据）；麦克风/通话未开始 |
| 基带/modem | ❌ | 未做 |
| 屏幕小瑕疵 | ⚠️ | 加载图像瞬间小块花屏、自愈（命令模式节奏问题） |

## 当前系统状态（2026-10-28，项目终止）

- **设备已损坏（引导链层面，2026-10-28 结案）**：PBL/EDL/UFS/存储完全可用
  （拔电池+插 USB 自动进 9008），但 PBL→XBL→ABL 不启动，任何 boot 镜像无法生效。
  完整救援记录见 docs/porting-notes.md 2026-10-28 节；唯一未试手段是官方 rawprogram
  全链刷写。NixOS 数据在 sda34，可随时经 EDL 读出。
- 历史正常状态（供恢复后对照）：设备跑 **NixOS 25.05**（自建内核 7.2.6 + venus.dtb +
  NixOS 官方 initrd），开机自动连 WiFi（固定 IP <LAN_PHONE_IP> / MAC 02:11:22:3c:4d:5e）
  并起 sshd
- 启动参数必须带 `init=/nix/var/nix/profiles/system/init`（`--no-bootloader` 安装不建根上的 /init）
- 内核更新**不需要 fastboot**：编译 → 打包 boot.img → `tools/vpush.sh` → 设备上 dd 到 `/dev/sde38` → reboot
- 内核里所有启动链要用的驱动必须 `=y`（initramfs 阶段没有模块可加载）

## 刷机注意（补充）

- 本机 fastboot 大包传输不可靠（`Requested download size is more than max allowed`），
  刷大镜像走 Windows 主机：`tools/win.sh "cd C:\\Users\\<windows-user>\\mi11 && fastboot.exe flash boot_b X.img"`
- 设备在跑我们内核时，串口日志两条路：Windows `COM3`（tools/wserial.sh）、本机 `/dev/ttyACM0`（tools/serial.sh）
