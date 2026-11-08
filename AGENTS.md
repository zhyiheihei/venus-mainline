# venus-mainline 项目约定

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

## 当前系统状态（2026-11-09，新机 12GB）

- 设备跑 **NixOS 25.05**（自建内核 7.2.6 + 修正后的 venus.dtb + NixOS 官方 initrd），
  开机自动连 WiFi（SSID `moli-1004-backup`，静态 IP <LAN_PHONE_IP> / MAC 02:11:22:3c:4d:5e），
  `ssh root@<LAN_PHONE_IP>` 可用（WiFi 稳定，无需拔插）
- 显示：`card1-DSI-1` connected/enabled/1440x3200，SDDM 自动登录 venus，Plasma Wayland 会话启动
- 串口：`venus-acm.service` 在 systemd 内重建 USB ACM gadget（`/dev/ttyGS0`），
  configfs gadget 在 switch_root 后残留、但 UDC 绑定会在 systemd 起来时丢，故必须由服务重建
- 启动参数必须带 `init=/nix/var/nix/profiles/system/init`（`--no-bootloader` 安装不建根上的 /init）
- 内核更新**不需要 fastboot**：编译 → 打包 boot.img → `tools/vpush.sh` → 设备上 dd 到 `/dev/sde38` → reboot
- 内核里所有启动链要用的驱动必须 `=y`（initramfs 阶段没有模块可加载）

### 配置部署（首选，不刷镜像）

```
本地 nix build（用下面 NIX_CONFIG 限定 substituter，否则 cache.zhyi.xin 会让每个 path 等 60s）
 → nix copy --no-check-sigs --to ssh://root@<LAN_PHONE_IP> <closure>
 → ssh root@<LAN_PHONE_IP> 'nix-env -p /nix/var/nix/profiles/system --set <closure>
     && <closure>/bin/switch-to-configuration switch'
```

### 三条硬约束（踩过的坑，别重犯）

1. **DTS 的 `memory` 节点必须是全零占位** `reg = <0x00 0x00 0x00 0x00>`：
   内存布局由 ABL 按实际 DDR 容量注入（手机真实 DT 就是这么写的）。写死旧 8GB 机的映射
   在新机上直接卡米标。
2. **rootfs 镜像的 `/nix/store` 必须是 `root:root`**：用普通用户 `cp -a` 灌根会让
   NetworkManager 以 "file has invalid owner" 跳过 wifi 插件 → wlan0 起来但无地址。
   构建时必须 `sudo chown -R 0:0 root` 并在挂载后复核。
3. **不要从 initramfs 往 `/etc/systemd/system/` 写 unit**：NixOS activation 启动时重写该目录，
   写入的 unit 会消失。加 unit 只能改配置再 switch。

## 刷机注意（补充）

- 本机 fastboot 大包传输不可靠（`Requested download size is more than max allowed`），
  刷大镜像走 Windows 主机：`tools/win.sh "cd C:\\Users\\<windows-user>\\mi11 && fastboot.exe flash boot_b X.img"`
- 设备在跑我们内核时，串口日志两条路：Windows `COM3`（tools/wserial.sh）、本机 `/dev/ttyACM0`（tools/serial.sh）
