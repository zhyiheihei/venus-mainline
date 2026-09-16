# venus-mainline 项目约定

- 本项目独立于 nixos-config 主仓,专门做小米11(venus)主线 Linux 适配,最终产出 NixOS
- 刷机红线:绝不 flash xbl*/xbl_config*/abl/tz/hyp/keymaster/devcfg/cmnlib*/qupfw/imagefv 与分区表;日常验证一律 `fastboot boot`,不落盘
- `backup/` 存原厂分区镜像与 ROM 包,永不入 git
- 厂商固件文件不进 git,只落本机 `/lib/firmware`
- flake 用 flake-parts;NixOS 配置保持 headless 最小集,图形栈等亮屏后再说
- 每个 milestone 完成后在 docs/porting-notes.md 追加日志,引用实际输出为证
- git 提交用 conventional commits,中文说明原因
