# venus-mainline 约定

- 本项目独立于 nixos-config，专门做小米 11（venus）主线 Linux 适配；对外只提供
  `nixosModules.venus`（板级模块）与 `nixos/kernel.nix`（内核 recipe）两个口子。
- 刷机红线：绝不 flash `xbl*`、`xbl_config*`、`abl`、`tz`、`hyp`、`keymaster`、
  `devcfg`、`cmnlib*`、`qupfw`、`imagefv`、`persist`、`modemst1/2` 与分区表。
- venus 的 ABL 不支持 `fastboot boot` 内存引导，只能写 `boot_b` 后重启。
- 刷写走 Windows 主机（`tools/win.sh`），NixOS 侧大传输会断；操作前先声明需要的手机状态。
- 厂商固件进 `nixos/firmware/`，不进 git 之外的路径。
- 代码内不写注释，说明写提交信息。
