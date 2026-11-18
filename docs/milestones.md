# 里程碑

每个里程碑都以"设备上实测到的现象"为准，附证据位置。里程碑之后不再回退该能力，
也不再用旧方案（例如预编译/冻结内核产物）替代它。

## M1 · 串口攻克（2026-11-13 22:49）

**定义**：26.11 原版（standalone）系统能在本项目的构建流程下正常启动，并且
**USB 串口可用**（Windows 侧出现 `VID_18D1&PID_4EE1` + `COM<n>`，可登录拿到 shell）。
WiFi 未通，不计入本里程碑。

**证据**：

| 项 | 值 |
|---|---|
| 闭包 | `/nix/store/8nbykdyf3cyiwsb6kwjj1h7qgwkkp0h9-nixos-system-venus-26.11.20260914.efe6f07` |
| boot.img | `/tmp/boot-K.img`（43810816 字节，md5 `43ed73b9a8ceb5ed32723c1f0e7c0b34`） |
| DTB | `527c521e5fb792c27608dbfc820f864b`（`dr_mode = "peripheral"`） |
| 日志 | `~/venus-logs/20261113-2257/venus-debug/` |
| 现象 | 22:49:22 `venus-serial-start: UDC=a600000.usb state=configured`；Windows `18D1=2 / COM=1 (COM3)` 连续稳定；串口登录得 `sh-5.3#`；桌面同时起来（journal 有 plasmashell） |

**关键改动**（都是板级模块内的，不是外挂）：

1. `&usb_1_dwc3 { dr_mode = "peripheral"; }`，去掉 `usb-role-switch` 与
   `&usb_1_dwc3_hs` 的 `remote-endpoint`。此前 OTG + pmic_glink 把端口留在
   host/source（`port0: data_role=host`），gadget 永不枚举。
2. gadget 建在 initrd 与 stage-2 共用的一份脚本里，幂等（`rm -f` 后再 `ln -s`，
   configfs 的 `ln -sfn` 不会替换），服务补 `path = [ util-linux coreutils bash ]`。

**遗留**：stage-2 之后串口会掉（initrd 的 gadget 在 switch_root 后失效），
需要 stage-2 强制重建一次（已在 `venus_usb_gadget force` 中实现，待验证）。

**明确废止**：预编译/冻结内核产物不再是本项目的手段。内核一律由
`nixos/kernel.nix` 从 kernel.org 源码 + 本仓库 config/补丁/DTS 构建（交叉编译，
与 nanopi-r5c 同形）。设备上 `/persistent/root/*.img.disabled` 只是历史镜像，
改名为 `.disabled` 以免被任何回滚逻辑使用。

## M2 · 系统升级到 26.11，WiFi 可用（2026-11-18 10:16）

**定义**：设备冷启动进入 NixOS **26.11** standalone，`wlan0` 自动关联目标 AP 并拿到
静态 IPv4 `192.168.0.150`，可 SSH 登录；`ath11k` 加载 WCN6851 hw1.1 固件且无
`MHI_CB_EE_RDDM`。串口不计入本里程碑（见遗留）。

**证据**：

| 项 | 值 |
|---|---|
| 闭包 | `/nix/store/kh69hbzshy2838c2g6rhms8r63dkrckb-nixos-system-venus-26.11.20260914.efe6f07` |
| boot.img | `/persistent/boot-kh69.img`（44298240 字节，md5 `b27358a998499649de58f4b19cad5b34`） |
| DTB | `527c521e5fb792c27608dbfc820f864b` |
| 实测 | 冷启动 2/2：41 秒 ping 通；`wlan0 UP 192.168.0.150/24`；SSID `moli-1004-backup`；rx/tx `2401.9 MBit/s 160MHz HE-MCS 11 HE-NSS 2`，signal -14 dBm；`ath11k_pci … wcn6855 hw1.1`，`fw_version 0x11008104`（WLAN.HSP.1.1.c3-00260）；`journalctl -b \| grep -c pcie` = 24；`MHI_CB_EE_RDDM` = 0；`systemctl --failed` = 0 |

**关键改动（三条，都是根因级）**：

1. **`systemd-networkd` 每个 link 只用一个 `.network` 文件**。此前 MAC 放在
   `10-wlan0.network`、静态 IPv4 放在 `20-wlan0.network`，networkd 只应用了前者：
   `wlan0: Configuring with /etc/systemd/network/10-wlan0.network.`（之后再无 20 的任何一行），
   于是只有 IPv6、没有 `192.168.0.150`，表现为"ping 不通、SSH 上不去"。而
   `wpa_supplicant` 其实早已关联成功：`wlan0: CTRL-EVENT-CONNECTED … completed`。
   修法：MAC 合进 `20-wlan0.network`，删除 `10-wlan0.network`。
2. **关掉 `venus.debug.enable`**：它往 cmdline 注入 `rd.debug` + `loglevel=8` +
   `systemd.log_level=debug` + `journald.forward_to_console` + `oops=panic` + `panic=30`，
   在唯一 115200 串口上等于把启动拖成分钟级，并把任何 oops 变成致命 panic。
3. **initrd 不再自己挂 rootfs**：为取证加的 `mount -o ro /dev/disk/by-label/nixos /mnt`
   永不 umount，是 switch-root 失败的已知来源；已删除，并给 `venus-serial` 加
   `TimeoutStartSec=25`、把等 `ttyGS0` 从 20s 压到 5s。

顺带修掉的真 bug：`venus-deadman` 因 unit-script 的 `set -e` 与
`grep -c` 零匹配返回 1，**每次都在启动同一秒失败**，所以从未能自动回滚
（这是本轮之前反复需要人工进 fastboot 的直接原因）。修法：`grep -c … || true`。

**回滚策略（单槽单系统，2026-11-18 起）**：

- 只有 26.11，不再保留 25.05 作为回退目标。`boot_a` 不再使用。
- 里程碑镜像固定为 `/persistent/boot-milestone.img`（= 本节 boot.img，md5 `70aaf450f373e5f528eb806cb22c2d87`）。
- `venus-deadman` 连续 3 次（每 90 秒）判定「无 IPv4 且 UDC 未 configured」时，先把当前
  `boot_b` 存成 `/persistent/boot-lastbad.img`，再回写里程碑镜像并重启；最多 3 次。

**遗留**：

- USB ACM 串口在 switch-root 后 `UDC` 落回 `default`，主机不再配置设备；
  拔插数据线也不恢复（设备侧 `current_speed=high-speed` 说明链路正常，
  是 PVE 没把该 USB 设备直通回 `MOLI-VM`）。串口不再是主通道，不计入本里程碑。
- OTG（USB 口外接键鼠）未做，作为下一个里程碑。
