# 预编译内核产物（设备上正在跑的那份）打成 nixpkgs 形状的内核包。
#
# 只在 P1（重建内核进不到用户态，见 docs/hardware-status.md）没解开之前用：
# 设备装机走这条，fleet/正常构建走 nixos/kernel.nix（源码构建）。
# 产物目录由 tools/pack-kernel.sh 摆好：Image + mod/ + modules.builtin* + modules.order + config + venus.dtb；
# artifacts 可参数化，别的机器/仓库也能指自己那份。
{ pkgs, lib, artifacts ? ./kernel, ... }:
let
  version = "7.2.6";
  configFile = artifacts + "/config";
in
(pkgs.callPackage ./kmods-package.nix { inherit artifacts; }).overrideAttrs (old: {
  # nixpkgs 内核包的契约属性（build.nix 里 modDirVersion/features/buildDTBs/target
  # 都是包属性；boot.kernelPackages 会 .override 重建内核，只有 passthru 能活下来）
  passthru = (old.passthru or { }) // {
    inherit version;
    modDirVersion = version;
    features = { };
    # NixOS 的 hardware.device-tree.enable 默认取 kernel.buildDTBs，
    # 自建包没这个属性会求值报错（我们不编 dtb，dtb 在打 boot.img 时用）
    buildDTBs = false;
    # boot.loader.kernelFile 默认取 target
    target = "Image";
    # nixpkgs 内核包的常规元数据，fleet 的内核模块会读
    kernelOlder = lib.versionOlder version;
    kernelAtLeast = lib.versionAtLeast version;
    commonMakeFlags = [ ];
    makeFlags = [ ];
    stdenv = pkgs.stdenv;
  }
  // lib.optionalAttrs (builtins.pathExists configFile) {
    config = import ./kernel-config-parse.nix { inherit lib; } configFile;
    # unstable 的 sysctl 模块会 inherit (kernel) configfile 生成内核参数相关的 sysctl
    configfile = configFile;
  };
})
