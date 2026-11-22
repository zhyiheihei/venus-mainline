{
  pkgs,
  lib,
  debug ? false,
  ...
}:
let
  linux = import ./linux-source.nix { inherit pkgs lib; };
  configfile = pkgs.runCommand "venus-kernel-config" { } (
    ''
      sed '/^CONFIG_INITRAMFS_SOURCE=/d' ${./kernel-config} > $out
    ''
    + lib.optionalString debug ''
      cat ${./kernel-config-debug} >> $out
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
