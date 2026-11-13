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
