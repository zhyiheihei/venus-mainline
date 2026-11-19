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
| 闭包 | `/nix/store/9a8mifabcqijyhz6g30s6ca2rac1h039-nixos-system-venus-26.11.20260914.efe6f07`（初版 kh69hbzs，加固后 9a8mifab） |
| boot.img | `/persistent/boot-milestone.img`（44298240 字节，md5 `70e14e69afb887b924b2f9aba02f0110`） |
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
- 里程碑镜像固定为 `/persistent/boot-milestone.img`（md5 `70e14e69afb887b924b2f9aba02f0110`），
  对应闭包记在 `/persistent/boot-milestone.closure`（deadman 用它判断"当前是否已是里程碑"）。
- `venus-deadman` 连续 3 次（每 90 秒）判定「无 IPv4 且 UDC 未 configured」时，先把当前
  `boot_b` 存成 `/persistent/boot-lastbad.img`，再回写里程碑镜像并重启；最多 3 次。

**里程碑之后的两处加固（2026-11-18，均已实测）**：

1. **WiFi 钉死 BSSID**：`networking.wireless.networks = { }` + `extraConfig` 单一 network 块
   （`bssid=be:fc:e7:9e:e8:d5`、`scan_freq=5180`）。原因：nixpkgs 会为同一 SSID 生成两条块
   （一条含 SAE/FT-SAE），叠加 `pmf=1`；实测出现
   `wlan0: authenticate with …:d5`（成功）后一直黏在 `…:d4` 上认证失败，
   表现为"WiFi 时好时坏"。
2. **deadman 的 IPv4 检测修正**：原来用 `ip -4 -br addr show | grep -c 'inet '`，
   而 `-br` 输出里没有 "inet" 字样（形如 `wlan0 UP 192.168.0.150/24`），于是恒判为"无网"，
   每 4~5 分钟自动回滚重启一次 —— **这是当天反复"失联"的主因**。
   改为 `ip -4 addr show dev wlan0 | grep -c 'inet '` 后实测
   `deadman: check 1/3 ip4=1`，uptime 13 分钟仍在线。

**遗留**：

- USB ACM 串口在 switch-root 后 `UDC` 落回 `default`，主机不再配置设备；
  拔插数据线也不恢复（设备侧 `current_speed=high-speed` 说明链路正常，
  是 PVE 没把该 USB 设备直通回 `MOLI-VM`）。串口不再是主通道，不计入本里程碑。
- OTG（USB 口外接键鼠）**已放弃**（2026-11-18）：
  1. `dr_mode = "host"` 单独改是可行的 —— 实测 xHCI 正常起来（`lsusb` 有 USB2/USB3
     两个 root hub），WiFi 与启动均不受影响。
  2. 但端口要对外供 5V 必须驱动 `pm8350_gpios 8`（vendor `xiaomi-sm8350-common.dtsi`
     的 `vbus-out-gpio`）。一旦常开供电、同时接着 PC，就是两端对顶；
     实测结果是黑屏、USB 全无、需人工进 fastboot。
  3. 用户明确不接受烧机风险，因此 OTG 整项放弃，仓库与设备均回到 `dr_mode = "peripheral"`
     （里程碑镜像 70e14e69…）。不再尝试该方向。

---

# M3 — fleet 文件系统布局（tmpfs / + btrfs /nix）+ WiFi 恢复 + 串口在 stage-2 存活

**日期**：2026-11-19
**闭包**：`3rp120jslmjzwf7nr256wf19haadgjs2-nixos-system-venus-26.11.20260914.efe6f07`
**boot.img md5**：`dad167af087c9d9cc5d59e97b033e324`（45772800 字节，= `/nix/persistent/boot-milestone.img`）
**DTB md5**：`527c521e5fb792c27608dbfc820f864b`（与 M1/M2 同一份，120626 字节）
**日志**：`~/venus-logs/20261119-1600/persistent/`（rsync 自设备 `/nix/persistent`），
设备侧 `/nix/persistent/venus-debug/journal-b.log`、`venus-diag.log`、`venus-dmesg.log`

## 定义

与 fleet 其它主机（opi5p / nanopi-r5c）完全同构的文件系统布局：`/` 是 tmpfs，
`/nix` 是独立 btrfs（label `NIXOS_NIX`，`compress-force=zstd` + `autodefrag`），
持久化数据在 `/nix/persistent`；userdata 分区 224G，首次启动用 `btrfs filesystem resize max` 扩容。

## 冷启动实测（2026-11-19 15:57 起）

| 判据 | 实测 |
|---|---|
| `/run/current-system` = `/run/booted-system` | 都是 `3rp120js…` |
| `/` | `tmpfs rw,nosuid,nodev,relatime,size=9098648k,mode=755` |
| `/nix` | `/dev/sda34 btrfs rw,nosuid,nodev,relatime,compress-force=zstd:3,ssd,discard=async,space_cache=v2,autodefrag` |
| `/nix` 容量 | `225G 3.5G 221G 2%`（`btrfs filesystem usage` → Device size 224.58GiB） |
| WiFi | `wlan0 UP 192.168.0.68/24`；`iw link` → SSID `moli-1004-backup`、freq 5300.0、signal -31 dBm、rx 2401.9 MBit/s 160MHz HE-MCS11 NSS2 |
| `systemctl --failed` | 0 |
| 串口 | `/sys/class/udc/*/state` = `configured`、`/dev/ttyGS0` 存在、Windows `COM3` 可用（**stage-2 也活着**） |
| `ath11k` | `wcn6855 hw1.1`、`fw_version 0x11008104`；dmesg 里 `MHI_CB_EE_RDDM` = 0 |
| PCIe | dmesg 里 `qcom-pcie` 17 行 |

## 关键改动

1. **cmdline 必须含 `root=fstab`**（`tools/boot-img.sh` 内置）。缺它时 systemd-initrd 不知道
   root 是谁，`initrd-fstab` 里的 `/`(tmpfs)、`/nix`(btrfs) 都不会生成 sysroot 挂载单元，
   `initrd-find-nixos-closure` 失败 → `initrd.target` 的 `OnFailure=emergency.target`
   (`replace-irreversibly`) 把 `venus-serial.service` 一起取消 → 无网、无串口、零日志。
2. **WiFi 不再钉 `scan_freq`**：AP 已从 ch36(5180) 换到 ch60(5300)，钉死频率导致永远扫不到该 BSS。
   保留 `bssid=be:fc:e7:9e:e8:d5`。
3. **`psk` 更正**：仓库里原来的 25 字符值与 AP 实际密码不符（`WPA: 4-Way Handshake failed -
   pre-shared key may be incorrect` / `WRONG_KEY`），以能连上的机器上 NetworkManager 的值为准。
4. **`/persistent` → `/nix/persistent`**（全仓 39 处）：tmpfs 根上写 `/persistent` 等于写内存。
   initrd 阶段的落盘同时修掉了 `[ -d "VLOGDIR:-/nonexistent" ]` 少写 `$` 的死代码（以前从没落过盘）。
5. **`venus-grow-nix` 改用 `btrfs filesystem resize max /nix`**（原来写 `resize2fs`，对 btrfs 无效）。
6. 新增 `venus-console-diag`（timer，40s 起每 120s）：把 `ip -br addr` / `iw link` /
   `systemctl --failed` / wifi 相关 dmesg 打到 `tty0`（手机屏幕）并追加到
   `/nix/persistent/venus-diag.log` —— 这是"无网无串口"时唯一还活着的通道。

## 部署方式（不再需要 fastboot）

```sh
nix copy --to ssh://root@192.168.0.68 <closure>
scp <boot.img> root@192.168.0.68:/nix/persistent/
ssh root@192.168.0.68 'dd if=/nix/persistent/<boot.img> of=/dev/disk/by-partlabel/boot_b bs=1M conv=fsync'
ssh root@192.168.0.68 'nix-env -p /nix/var/nix/profiles/system --set <closure>'
ssh root@192.168.0.68 'systemctl reboot'
# 读回校验：head -c <boot.img 大小> /dev/disk/by-partlabel/boot_b | md5sum
```

## 里程碑之后

- deadman 的回滚目标已更新为 M3（`boot-milestone.img` = `c04066f9…`，
  `boot-milestone.closure` = `3rp120js…`），且 M3 之前的镜像 `70e14e69…` 已不是当前布局。

## M3 最终版本（2026-11-19 16:06 二次冷启动验收）

首次验收后删掉了历史遗留的坏单元覆盖（`systemd.services."wpa_supplicant-wlan0"` 只设
`ProcSubset`/`ProtectProc`，生成的单元没有 `ExecStart`，systemd 261 直接拒载：
`Service has no ExecStart=, ExecStop=, or SuccessAction=. Refusing.`），重新构建并再次冷启动验收：

- 闭包 `3rp120jslmjzwf7nr256wf19haadgjs2-…`，boot.img md5 `dad167af087c9d9cc5d59e97b033e324`
- 实测：`wlan0 UP 192.168.0.68/24`、`systemctl --failed` = 0、
  `systemctl list-unit-files | grep -c wpa_supplicant-wlan0` = 0、
  `udc=configured` + `/dev/ttyGS0` 存在、`MHI_CB_EE_RDDM` = 0、`wpa_supplicant.service` active
- `/nix/persistent/boot-milestone.img` 与该闭包 `.closure` 已同步为这一版（先验收后更新）

---

# M4 — fleet 版跑通（nixos-config 的 `nixosConfigurations.venus` 在真机上起来）

**日期**：2026-11-19（17:24 首次跑通；19:00 更新为调试/正式拆分版）
**闭包**：`zybiwskqdb06xx8my3y67700yc1c0pw8-nixos-system-venus-26.11pre1122823.04906337b6d5`
**boot.img md5**：`9f9387fdb8cc34d75cb005acf8943de8`（40116224 字节）
**DTB md5**：`527c521e5fb792c27608dbfc820f864b`
**构建命令**（在 `nixos-config` 里，用本地两个仓覆盖远端）：

```sh
nix build .#nixosConfigurations.venus.config.system.build.toplevel \
  --override-input venus-mainline path:../venus-mainline \
  --override-input secrets path:../nixos-secrets
```

## 定义

`nixos-config` 里的 fleet 角色（`hosts/venus`，index 113、`home-lan` interconnect
`192.168.0.68`、zerotier `447c5027d6`、`server` tag、`firewalled = true`）能在这台手机上
完整跑起来：LT interconnect、zerotier、powerdns/coredns、wgmesh 全部就位，WiFi 由 sops 提供口令。

## 冷启动实测（17:24 刷入后重启）

| 判据 | 实测 |
|---|---|
| booted | `i85wnar0syxm…-26.11pre1122823.04906337b6d5` |
| `/` | `tmpfs rw,nosuid,nodev,relatime,size=9098648k,mode=755` |
| `/nix` | `/dev/sda34 btrfs rw,…,compress-force=zstd:3,ssd,discard=async,space_cache=v2,autodefrag,subvolid=5`；`225G 5.2G 219G 3%` |
| WiFi | `wlan0 UP 192.168.0.68/24`；SSID `moli-1004-backup`、freq 5300.0、signal -32 dBm、2401.9 MBit/s 160MHz HE-MCS11 NSS2 |
| sops | `sops-install-secrets` **active**，`/run/secrets -> /run/secrets.d/1` |
| WiFi 单元 | `wpa_supplicant-wlan0.service` active |
| LT / zerotier | `zttalxbxtu 198.18.0.113/24`；`zerotier-cli info` → `200 info 2991e03d81 1.16.0 ONLINE` |
| ath11k | `MHI_CB_EE_RDDM` 0；`qcom-pcie` 17 行；`wmi command` 超时 0 次 |
| SSH | **端口 2222**（fleet 约定，不是 22） |
| failed units | `knot.service`、`nginx.service` —— 都因为 `/nix/sync-servers/{ltnet-zones,acme}` 不存在（fleet 侧 sync-servers 内容，非本移植问题） |
| 串口 | `udc` = `not attached`（fleet 关掉了 `venus-usb-keepalive`；initrd 里的 gadget 在这一版没绑上，见"遗留"） |

## 关键改动（三处，缺一不可）

1. **secrets 身份对齐**（`nixos-config/hosts/venus/host.nix` + `nixos-secrets/.sops.yaml`）：
   设备 host key 换成新机生成的那把（`age1wnuv9fam…`），9 个 venus 实际用到的 yaml 跑
   `sops updatekeys`。之前设备是"重装后新 key"，而 `.sops.yaml` 里还是旧的
   `age1qxazsz5…`，于是 `sops-install-secrets` 报
   `Error getting data key: 0 successful groups required, got 0`，WiFi 完全没口令。
2. **WiFi 单元必须放开 `/proc` 子集**：nixpkgs 的 wpa_supplicant 模板 + `lantian.harden`
   默认档（mkOptionDefault，优先级低于模板）叠加后 `ProcSubset=pid`，该单元起 mount
   namespace 时直接失败：
   ```
   wpa_supplicant-wlan0.service: Failed to set up mount namespacing:
     /proc/sys/net: No such file or directory
   Main process exited, code=exited, status=226/NAMESPACE
   ```
   `venus-fleet.nix` 里对该单元 `ProcSubset = mkForce "all"`、`ProtectProc = mkForce "default"`。
3. **boot.img 的 cmdline 必须带板级三条**：fleet 闭包的 `kernel-params` 里没有
   `regulator_ignore_unused pd_ignore_unused clk_ignore_unused`。缺它们时固件加载成功
   （`fw_version 0x11008104` 正常），但 40 秒后
   `ath11k_pci: wmi command 12291 timeout` / `failed to send WMI_SCAN_CHAN_LIST cmd`，
   `wlan0` 永远 DOWN。`tools/boot-img.sh --from-kernel-params` 现在以闭包自带的
   `kernel-params` 为底、去重并裁掉无关键（`vt.default_*` 等会把 512 字节主字段撑爆），
   再补回这三条。

## M4 更新（19:00）：调试/正式拆分 + 26.11 写法清理

- 正式版不再有任何常驻诊断定时器（console-diag / net-watch / usb-watch / probe 全部只在
  `venus.debug.enable = true` 时存在）；串口 getty 不再 `--autologin root`；initrd 不再起
  `setsid sh`；`venus-deadman` 在正式版只取证（存 `boot-lastbad.img`）不 dd 不改引导、不重启。
- 反过来，`venus-pstore-copy`（ramoops → 持久盘）从调试版移进正式版：生产里 pstore 有写入
  却没人搬运，崩溃现场会随内存丢失。
- 26.11 写法：`networking.wireless.userControlled`（原名带 `.enable`，26.11 已 mkRenamed）、
  `after = systemd-udevd.service`（`systemd-udev-settle.service` 已不存在）、journald/logind
  只留 `settings.*`、调试版用 `udev.log_level=debug` + `boot.initrd.systemd.emergencyAccess`
  取代 dracut 的 `rd.debug`/`boot.shell_on_fail`、`kernel-config-debug` 里
  `PSTORE_DEFLATE_COMPRESS→PSTORE_COMPRESS` 与 `MTD_MTDOOPS→MTD_OOPS`。求值 warning 归零。
- **踩坑记录（重要）**：把 `fileSystems."/run/nullfs".enable = lib.mkForce false` 当"死配置"
  删掉后，fleet 侧定义的 `nullfsvfs /run/nullfs` 进了 fstab，而本板内核没有 nullfsvfs 模块
  （`boot.extraModulePackages` 被 mkForce 成 []），18:12 那次启动直接死在 early boot：
  `/nix/persistent` 一个字都没写、无串口、无网，只能人工进 fastboot。判据：失败闭包与已验收
  闭包的 `/etc/fstab` **只差这一个 mount 条目**。已恢复并加了长注释。
- 19:00 验收（闭包 `zybiwskq…` / boot.img `9f9387fd…`）：`wlan0 UP 192.168.0.68/24`（freq 5300、
  -31 dBm）、`/nix` 225G（用 5.3G）、调试单元 0 个、`venus-pstore-copy` success、
  `MHI_CB_EE_RDDM` 0、`wmi command` 超时 0、`systemctl --failed` 只有 knot（缺 /nix/sync-servers）。

## 遗留

- **fleet 下串口不可用**：`udc = not attached`。fleet 角色故意关掉了 `venus-usb-keepalive`
  （nixos-config 的 hardening 策略要求 gadget 服务带 hardening+confinement），而 initrd 里的
  `venus-serial`（已改挂 `sysinit.target`）在这一版仍未把 gadget 绑上，日志也没有落盘
  （落盘段落以 `/dev/ttyGS0` 存在为前提）。WiFi 通道已稳定，暂不阻塞；要恢复串口需要
  在 `venus-fleet.nix` 里给 gadget 服务补 hardening 配置后重新启用 keepalive。
- `knot.service` / `nginx.service` 需要 `/nix/sync-servers/*`，属于 fleet 侧的同步内容，
  与本移植无关（同样在其它 fleet 主机上依赖同步任务）。
