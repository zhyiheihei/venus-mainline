# venus 自建内核 recipe：源码 + config + 补丁 + DTS 全由本仓库（git）决定，
# 形状对标 nixos-hardware 的 raspberry-pi/common/kernel.nix —— 别的仓库
# （nixos-config 的 venus 主机）直接
#   lantian.kernel = pkgs.callPackage (inputs.venus-mainline + "/nixos/kernel.nix") { };
# 就能构建，不必分发二进制产物。
#
# 注意（P1）：docs/hardware-status.md 记录"脚本化补丁后的重建内核进不到用户态"，
# 定位必须 early boot 串口。在那之前设备装机用 nixos/kernel-prebuilt.nix（设备上跑的那份）。
{
  pkgs,
  lib,
  # NixOS 的 boot.kernelPackages 会用 .override 传 randstructSeed/kernelPatches/features 进来
  # （nixos/modules/system/boot/kernel.nix 的 kernel = super.kernel.override (...)）；
  # 我们只接住、不转给 linuxManualConfig —— 这个内核的补丁与特性由本 recipe 定死。
  ...
}:
let
  version = "7.2.6";
  # 内核源码：官方 tarball，hash 与 kernel.org 的 sha256sums 一致；
  # （不叫 src：callPackage 会把包集里的同名属性注入进来）
  src = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${version}.tar.xz";
    hash = "sha256-A5rvhPKwmUrto/T8/D0C7J16m7uQIOomTEP0Rshg9gY=";
  };
  # 内嵌 initramfs：busybox 用 nixpkgs 的静态 busybox（不往 git 塞二进制），
  # init 用仓库里那份，与设备上能启动的形态一致
  initramfs = pkgs.runCommand "venus-initramfs" { } ''
    mkdir -p $out/bin $out/dev $out/proc $out/sys $out/tmp $out/run $out/etc
    install -m755 ${pkgs.pkgsStatic.busybox}/bin/busybox $out/bin/busybox
    ln -s busybox $out/bin/sh
    install -m755 ${../kernel/venus/initramfs/init} $out/init
  '';
  # 仓库里的内核改动（面板/触摸/pcie/regulator/dpu/battmgr/ath11k 补丁 + venus DTS）：
  # 跑仓库那份幂等脚本。脚本用 "$here/.." 去找 kernel/venus/*，所以先把脚本与
  # kernel/venus 按仓库布局摆进一个 store 目录（直接拿单文件会让 $root 指到 store 根）。
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
  # 基线 config 里的内嵌 initramfs 指向构建机本地路径，这里换成 Nix 里这份
  configfile = pkgs.runCommand "venus-kernel-config" { } ''
    sed '/^CONFIG_INITRAMFS_SOURCE=/d' ${./kernel-config} > $out
    printf 'CONFIG_INITRAMFS_SOURCE="%s"\n' ${initramfs} >> $out
  '';
in
pkgs.linuxManualConfig {
  pname = "linux-venus";
  inherit version configfile;
  modDirVersion = version;
  src = patchedSrc;
  # build.nix 只用到 isSet/isYes/isNo/isModule 这几个判断（读的是仓库里那份基线 config）
  config = import ./kernel-config-parse.nix { inherit lib; } ./kernel-config;
}
