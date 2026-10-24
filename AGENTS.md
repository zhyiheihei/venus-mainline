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
