# USB / 串口状态与结论

## 现状

| 状态 | Windows 侧现象 |
|---|---|
| ABL / fastboot | `VID_18D1&PID_D00D` 可见，`fastboot devices` 有序列号 |
| 我们的 Linux（25.05 救援、26.11 都一样） | `18D1=0`、`COM=0`，连"未知设备"条目都没有 |
| 设备侧日志 | `venus-acm-start: UDC=a600000.usb state=configured`、`serial-getty@ttyGS0` 已启动 |

两边矛盾：设备自认为 gadget 已配置，主机侧却完全看不到设备。

## 已确认的旁证

- 早期日志抓到 `port0: data_role=host / power_role=source`，即 Type-C 口在为线缆供电、
  按 host 角色工作。
- 切回 ABL（fastboot）后端口角色被重置，所以「重插一次才能看到 fastboot」。
- Windows VM 内的 USB 控制器：QEMU xHCI（`VEN_1B36&DEV_000D`）为幻影（Code 45），
  实际挂在 QEMU ICH9 UHCI（`VEN_8086&DEV_2934..2938`）上；没有直通控制器出现在 VM 里。

## 待查（进救援系统执行，只读）

```sh
ls /sys/class/typec/
cat /sys/class/typec/port*/data_role /sys/class/typec/port*/power_role /sys/class/typec/port*/role
ls /sys/class/usb_role/
cat /sys/class/usb_role/*/role
dmesg | grep -iE 'typec|ucsi|altmode|dwc3|usb_role|a600000'
cat /sys/class/udc/a600000.usb/state
```

## 尝试的修法（按风险从低到高）

1. `echo device > /sys/class/usb_role/a600000.usb-role-switch/role`（运行期切换，重启失效）
2. 在 DTS 里关掉 `pmic_glink_altmode` 的端口接管，让 dwc3 固定 peripheral
3. 用 `CONFIG_TYPEC` 相关关配置排除 UCSI/altmode 抢角色

修好后判据：Windows 出现 `VID_18D1&PID_4EE1` 与 `COM<n>`，`/dev/ttyGS0` 上有 root shell。
