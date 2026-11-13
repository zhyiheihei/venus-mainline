{
  pkgs,
  lib,
  debug ? false,
  ...
}:
let
  version = "7.2.6";
  src = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${version}.tar.xz";
    hash = "sha256-A5rvhPKwmUrto/T8/D0C7J16m7uQIOomTEP0Rshg9gY=";
  };
  initramfs = pkgs.runCommand "venus-initramfs" { } ''
    mkdir -p $out/bin $out/dev $out/proc $out/sys $out/tmp $out/run $out/etc
    install -m755 ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/busybox
    ln -s busybox $out/bin/sh
    install -m755 ${../kernel/venus/initramfs/init} $out/init
  '';
  patchset = pkgs.runCommand "venus-patchset" { } ''
    mkdir -p $out/tools $out/kernel
    cp ${../tools/apply-kernel-patches.sh} $out/tools/apply-kernel-patches.sh
    cp -r ${../kernel/venus} $out/kernel/venus
  '';
  patchedSrc = pkgs.runCommand "linux-venus-${version}-src" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    mkdir source
    tar xf ${src} --strip-components=1 -C source
    cd source
    export KSRC=$PWD
    bash ${patchset}/tools/apply-kernel-patches.sh
    cp ${../kernel/venus/sm8350-xiaomi-venus.dts} arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dts
    sed -i '/sm8350-xiaomi-venus.dtb/d' arch/arm64/boot/dts/qcom/Makefile
    printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= sm8350-xiaomi-venus.dtb\n' >> arch/arm64/boot/dts/qcom/Makefile
    cd ..
    mv source $out
  '';
  configfile = pkgs.runCommand "venus-kernel-config" { } (''
    sed '/^CONFIG_INITRAMFS_SOURCE=/d' ${./kernel-config} > $out
  '' + lib.optionalString debug ''
    cat ${./kernel-config-debug} >> $out
  '' + ''
    printf 'CONFIG_INITRAMFS_SOURCE="%s"\n' ${initramfs} >> $out
  '');
in
pkgs.linuxKernel.manualConfig {
  pname = "linux-venus";
  inherit version configfile;
  modDirVersion = version;
  src = patchedSrc;
  config = import ./kernel-config-parse.nix { inherit lib; } ./kernel-config;
}
