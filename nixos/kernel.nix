{
  pkgs,
  lib,
  debug ? false,
  ...
}:
let
  linux = import ./linux-source.nix { inherit pkgs lib; };
  # 配置文件也用 writeText 落成"内容决定 store path"的独立输入；直接用
  # ${./kernel-config} 会把 flake 源码树的哈希带进内核 derivation（同 linux-source.nix
  # 里 patchset 的处理），换来换去就重编内核。
  baseConfig = pkgs.buildPackages.writeText "venus-kernel-config-base" (builtins.readFile ./kernel-config);
  debugConfig = pkgs.buildPackages.writeText "venus-kernel-config-debug" (builtins.readFile ./kernel-config-debug);
  configfile = pkgs.buildPackages.runCommand "venus-kernel-config" { } (
    ''
      sed '/^CONFIG_INITRAMFS_SOURCE=/d' ${baseConfig} > $out
    ''
    + lib.optionalString debug ''
      cat ${debugConfig} >> $out
    ''
  );
in
pkgs.linuxKernel.manualConfig {
  pname = "linux-venus";
  version = linux.version;
  modDirVersion = linux.version;
  src = linux.patchedSrc;
  inherit configfile;
  config = import ./kernel-config-parse.nix { inherit lib; } ./kernel-config;
}
