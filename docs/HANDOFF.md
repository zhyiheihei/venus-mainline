# 交接文档（写给下一个接手的 agent）

> **最新状态（2026-11-19，里程碑 M3）：NixOS 26.11 + fleet 文件系统布局 + WiFi + 串口全部跑通，
> 冷启动验收通过。** 细节与判据见 `docs/milestones.md` 的 M3，实验过程见 `docs/experiments.md`。
>
> 闭包 `3rp120jslmjzwf7nr256wf19haadgjs2-nixos-system-venus-26.11.20260914.efe6f07`；
> boot.img md5 `dad167af087c9d9cc5d59e97b033e324`（= `/nix/persistent/boot-milestone.img`）；
> DTB md5 `527c521e5fb792c27608dbfc820f864b`。
>
> 置信度约定：✅ = 今天带命令实测过；🔶 = 推断或历史记录、用前请复验。

## 一、当前设备状态（✅ 2026-11-19 15:57 冷启动后实测）

- 小米 11（venus / SM8350），**12GB 内存**（旧 8GB 机已报废）。槽位 a=Android(EvoX)、b=NixOS；
  本项目只用 `boot_b`，`boot_a` 不刷不切。
- 文件系统：`/` = tmpfs（`size=80%,mode=755`）、`/nix` = btrfs label `NIXOS_NIX`
  （`compress-force=zstd:3,autodefrag`，已扩到整块 **225G，可用 221G**）、持久化在 `/nix/persistent`。
- WiFi：`wlan0 UP 192.168.0.68/24`，SSID `moli-1004-backup`、**freq 5300（ch60）**、
  2401.9 MBit/s / 160MHz / HE-MCS11 / NSS2、signal -31 dBm；`ath11k_pci … wcn6855 hw1.1`，
  fw `0x11008104`；`MHI_CB_EE_RDDM` = 0；dmesg 里 `qcom-pcie` 17 行。
- 系统：`/run/current-system` = `/run/booted-system` = `3rp120js…`；`systemctl --failed` = 0。
- 串口：stage-2 **也活着** —— `/sys/class/udc/*/state` = `configured`、`/dev/ttyGS0` 存在、
  Windows 侧 `COM3` 可用。

## 二、两条调试通道

**主通道：WiFi SSH**

```sh
ssh root@192.168.0.68          # 公钥登录；PasswordAuthentication=no
```

**备用通道：USB ACM 串口（Windows COM3）**

```sh
tools/serial.sh "<命令>" [秒]            # 发一条命令并读回
tools/serial.sh --read 10                # 只读
MI11_WAIT=200 tools/serial.sh --read 260  # 端口还没枚举时先等（boot 前起抓取用）
```

- 串口上 `ttyGS0` 是 `venus` 用户自动登录 + 无密码 sudo；**root 需要密码**。
- `ser.ps1` 会一直占用端口直到本次读结束，同一时刻只能有一个进程开 COM3（第二个会报
  "访问被拒绝"）。抓取脚本的输出是在**结束时**一次性打印的，中途看文件是 0 字节，别误判成没抓到。
- 想通过串口传密码类内容，先 `stty -echo`，否则会出现在日志里。

**第三条通道（无网无串口时）：手机屏幕**。`venus-console-diag`（timer，40s 起每 120s）会把
`ip -br addr` / `iw link` / `systemctl --failed` / wifi 相关 dmesg 打到 `tty0`，同时追加
`/nix/persistent/venus-diag.log`。故障时让用户拍照即可。

## 三、部署（首选：完全不碰 fastboot）

设备跑起来后：

```sh
C=/nix/store/<closure>-nixos-system-venus-...
tools/boot-img.sh "$C" /tmp/boot.img                     # cmdline 唯一来源，含 root=fstab
nix copy --no-check-sigs --to ssh://root@192.168.0.68 "$C"
scp /tmp/boot.img root@192.168.0.68:/nix/persistent/
ssh root@192.168.0.68 "
  dd if=/nix/persistent/boot.img of=/dev/disk/by-partlabel/boot_b bs=1M conv=fsync
  head -c $(stat -c%s /tmp/boot.img) /dev/disk/by-partlabel/boot_b | md5sum   # 读回校验
  nix-env -p /nix/var/nix/profiles/system --set $C
  nix-store --add-root /nix/persistent/system-gcroot --indirect -r $C
  systemctl reboot"
```

只有 **rootfs 本身**要换（新增 store 路径、磁盘布局变化）才需要重做 userdata 镜像：

```sh
tools/mkbtrfs-img.sh "$C" ~/.cache/venus-k27/venus-btrfsN.simg --hostkey <host key 文件>
# 然后 fastboot flash userdata venus-btrfsN.simg（走 Windows 主机，见第六节）
```

六件套必须同源并登记 md5：kernel / dtb / initrd / `init=` / profile / cmdline。
`tools/boot-img.sh` 保证前五项取同一个闭包，cmdline 是它内置的唯一来源。

## 四、里程碑与回滚

- 回滚目标：`/nix/persistent/boot-milestone.img`（当前 md5 `c04066f9…`）+
  `/nix/persistent/boot-milestone.closure`（当前 `3rp120js…`）。
- `venus-deadman`：启动 3 分钟后开始，每 90 秒判一次「无 IPv4 且 UDC 未 configured」，
  连续 3 次才动手；先把当前 `boot_b` 存成 `/nix/persistent/boot-lastbad.img`，再回写里程碑镜像并重启；
  若当前已经在跑里程碑闭包则只记录不回写（防死循环）。
- **更新里程碑的顺序是硬规矩：先冷启动验收通过，再写 milestone。** 11-18 违反过一次，
  把坏镜像写成 milestone，deadman 反复回滚到坏镜像，设备彻底失联。

## 五、三条硬前提（缺一条 WiFi 就死，全部有日志实证）

1. **内核必须有 `userspace-consumer` 补丁**（`tools/apply-kernel-patches.sh` 负责，幂等）。
   缺它时五路 WiFi regulator probe 报
   `reg-userspace-consumer regulator-wifi_aon: error -EBUSY: Failed to get supply 'vout'`
   与 `probe with driver reg-userspace-consumer failed with error -16`，
   `/sys/bus/platform/devices/regulator-wifi_*/state` 不存在 → `venus-wifi-power` 的
   `echo enabled` 全部落空 → PCIe 永远 `Device not found` → ath11k 一行日志都没有。
2. **WCN6851（hw1.1）的 `.num_vdevs` 必须是 3**（不是 WCN6855 hw2.0 的 4）：4 时固件自复位
   `firmware crashed: MHI_CB_EE_RDDM` + `failed to receive wmi unified ready event: -110`。
   `tools/apply-kernel-patches.sh` 第 8 段负责。
3. **`dtbo_b` 必须写零**（24MB 全零镜像）。只要 dtbo 槽里有 overlay，ABL 就用 dtbo 的 DTB，
   自建 DTB 完全不生效 —— 症状是显示正常但串口与 WiFi 同时不在。
   刷零镜像后 **boot.img 的 cmdline 里必须有 `root=fstab`**，否则 systemd-initrd 不知道 root 是谁，
   会走到 emergency 并把 `venus-serial.service` 一起取消（详见第六节第 5 条）。

## 六、坑位清单（全部踩过）

1. **`systemd-networkd` 每个 link 只用一个 `.network` 文件**（按文件名取第一个匹配）。
   MAC 放 `10-wlan0`、IPv4 放 `20-wlan0` 时只应用前者 → 只有 IPv6、没有 IPv4。
   MAC 与地址必须写在同一个文件里。
2. **unit 脚本带 `set -e`**：`x=$(... | grep -c ...)` 零匹配会让整个脚本退出；
   `ip -4 -br addr` 的简要输出**不含 "inet" 字样**（形如 `wlan0 UP 192.168.0.68/24`），
   用它 grep 'inet ' 恒为 0 —— 曾让 deadman 把"WiFi 通着"误判成无网并每 4~5 分钟回滚重启。
3. **`venus.debug.enable = true`** 会往 cmdline 注入 `rd.debug` / `loglevel=8` / `oops=panic` /
   `panic=30`，把 115200 串口灌爆并让任何 oops 变致命。排查请用 `nixosConfigurations.venus-debug`
   单独构建，别改主配置。
4. **WiFi**：可以钉 `bssid=be:fc:e7:9e:e8:d5`（同 SSID 的 `…:d4` 认证不过），
   **但不要钉 `scan_freq`** —— AP 会换信道（11-19 已从 ch36/5180 换到 ch60/5300），
   钉死后 wpa_supplicant 永远扫不到该 BSS（`wlan0 DOWN`、`iw link` 报 `Not connected`）。
   `psk` 也要以**能连上的机器**上 NetworkManager 的值作准（11-19 仓库里是 25 字符旧值，
   握手报 `WPA: 4-Way Handshake failed - pre-shared key may be incorrect` / `WRONG_KEY`）。
5. **boot.img 只能由 `tools/boot-img.sh` 生成**。手拼 mkbootimg 命令行漏掉 `root=fstab` 时，
   systemd-initrd 没有 root 描述 → `/`(tmpfs)、`/nix`(btrfs) 都不生成 sysroot 挂载单元 →
   `initrd-find-nixos-closure` 失败 → `initrd.target` 的 `OnFailure=emergency.target`
   (`replace-irreversibly`) 把 `venus-serial.service` 一起取消 → **既没网也没串口，零日志**
   （11-19 连续三次"完全起不来"就是这个，同闭包同 DTB，只差这一个参数）。
6. **`/persistent` 不存在**：tmpfs 根上没有这个目录，写它等于写内存。
   全仓已统一为 `/nix/persistent`。initrd 阶段的落盘直接写 `/sysroot/nix/persistent`。
7. **`btrfs` 扩容不能用 `resize2fs`**：`venus-grow-nix` 用 `btrfs filesystem resize max /nix`。
   另外它靠 `/nix/persistent/.grow-done` 标记只做一次，换新镜像时注意这个标记是否残留。
8. **`wpa_supplicant-wlan0.service` 是历史遗留的坏单元**：仓库里只覆盖了 `ProcSubset`/`ProtectProc`，
   生成的单元没有 `ExecStart`，systemd 261 直接拒载（`Service has no ExecStart=… Refusing.`）。
   真正干活的是 `wpa_supplicant.service`。这个覆盖块应当删掉（尚未删，见待办）。
9. **刷机一律走 Windows 主机**（`molis@192.168.0.143`，platform-tools 在
   `C:\Users\molis\mi11\platform-tools`）：本机 fastboot 大传输会断。
   必须用 `tools/win-fastboot.sh`（调前调后 `taskkill fastboot.exe`，内置超时），
   禁止直接 `tools/win.sh "fastboot …"`（找不到设备会无限等待，遗留进程会在下次插线时突然执行）。
10. **PVE 直通会抢 USB**：手机在 fastboot ↔ Linux gadget 之间重新枚举时，MOLI-VM 侧设备可能消失，
    拔插数据线（机箱后置口）即可恢复。Windows 侧完全看不到 18D1 时先重插，不要怀疑手机。
11. **ABL 不支持 `fastboot boot` 内存引导**（静默不执行）：验证只能写 `boot_b` 后 `reboot`。
12. **EDL（9008）是最后手段**：本机是"免授权 9008"可用的最后一代，`prog_firehose_ddr.elf`
    改名即可绕授权；工具在 `~/mi11-work/`（MiFlash 自带 QSaharaServer + fh_loader）。
    大分区读会丢块，不要用于校验。
13. **厂商固件默认不进 git**，唯一例外 `nixos/firmware/ath11k/WCN6855/hw1.1/`（4MB，WiFi 必需）。
    内核产物（`Image`、`*.dtb`、`modules/`、解包的 `out/`）一律不进 git。
14. **`nixos/configuration.nix` 的 WiFi `psk` 只提交占位符**（`<WIFI_PSK>`），明文留在工作区。

## 七、日志与取证

- 拉全量日志：`rsync -az root@192.168.0.68:/nix/persistent/ ~/venus-logs/<时间戳>/persistent/`
  （`tools/fetch-logs.sh` 是串口/recovery 时代的路子，现在直接 rsync 更快）。
- 设备侧固定位置：
  | 阶段 | 位置 |
  |---|---|
  | initrd（switch_root 之前） | `/nix/persistent/venus-initrd-boot.log`（`venus-serial` 落盘） |
  | stage-2 之后 | `journalctl -b`，另有 `/nix/persistent/venus-debug/{journal-b,dmesg,failed}.log` |
  | 周期快照 | `/nix/persistent/venus-diag.log`（含 `iw link`、failed units、wifi dmesg） |
  | 内核崩溃 | `/sys/fs/pstore`（ramoops 节点 `0xa9000000`，只配了 `console-size`） |
- 结论必须落在日志原句上，同一结论至少两条独立证据；拿不到日志的轮次记为"无效实验"。
- "ping 不通"不是判据：区分不了内核崩、用户态没起、WiFi 没连。

## 八、构建

```sh
# 系统闭包（内核未变时是增量，几十秒到几分钟）
nix build --no-link --print-out-paths .#nixosConfigurations.venus.config.system.build.toplevel

# 内核（交叉编译；源码树先打补丁）
KSRC=$HOME/.cache/venus-k27/src tools/apply-kernel-patches.sh
nix develop -c bash -c 'make -C $HOME/.cache/venus-k27/src O=$HOME/.cache/venus-k27/build \
  ARCH=arm64 CROSS_COMPILE=aarch64-unknown-linux-gnu- -j12 Image dtbs'
```

- flake 源按 git 索引打包：**新增文件必须先 `git add`**，否则不进闭包（踩过：两次构建同一哈希）。
- 长构建会派发到 `opi5p`（aarch64 原生）跑 initrd 等步骤；`cache.nixos.org` 当前不可达，
  构建日志里会有大量 15s 超时重试，属正常噪音。
- 内核红线：不设 `CONFIG_INITRAMFS_SOURCE`（内嵌 initramfs 会遮住 nixpkgs 的 `/bin`）；
  改 config 后必须核对生成物里目标符号的实际取值。

## 九、刷写红线

绝不 flash：`xbl*`、`xbl_config*`、`abl`、`tz`、`hyp`、`keymaster`、`devcfg`、`cmnlib*`、
`qupfw`、`imagefv`、`persist`、`modemst1/2` 与分区表。
可写：`boot_b`、`dtbo_b`、`userdata`。

## 十、周边

- `nixos-config` 仓库里管理着 fleet 与本网络的各台机器；其中 `hosts/router` 就是本网的路由器
  `192.168.0.1`（SSH 在 **2222** 端口，root 公钥登录；`wlan0` 的 AP 叫 `moli-rk-wifi`）。
  我们设备连的 `moli-1004-backup`（BSSID `be:fc:e7:9e:e8:d5`）是**另一台**设备，
  不在 nixos-config 里。排查网络问题时可以用路由器看 DHCP 租约（kea）与桥表：
  `ssh -p 2222 root@192.168.0.1 'cat /var/lib/kea/dhcp4.leases; bridge fdb show | grep <mac>'`。
- 历史文档 `docs/porting-notes.md` 已不在仓库里（随早期分支 reset 丢失），其中的"误判记录"
  不再可查；本文件第六节与 `docs/experiments.md` 是现在唯一权威。

## 十一、待办（按优先级）

1. `docs/usb-serial.md`、`docs/research.md` 两篇还是 25.05/串口攻坚时代的记录，
   里面的 IP（192.168.0.150）与"串口不可用"结论已过期，需要按 M3 重写或归档。
2. `tools/deploy.sh` / `tools/fetch-logs.sh` / `tools/deploy-2611.sh` 还是刷机+串口时代的流程，
   要么改成 M3 的 SSH+dd 流程，要么标注废弃。
3. `venus-deadman` 目前把"无 IPv4"当作失败判据之一；M3 之后 WiFi 有独立通道（串口 + 屏幕 +
   `/nix/persistent` 日志），可以考虑放宽避免误回滚。
