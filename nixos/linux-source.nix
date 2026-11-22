{
  pkgs,
  lib,
}:
let
  version = "7.2.6";

  # 只有 kernel/venus 下真正参与构建的文件进内核 derivation。用 filterSource /
  # writeText 把它们变成"内容决定 store path"的独立输入；直接用 ${../kernel/venus}
  # 会把整个 flake 源码树的哈希带进内核 —— 结果是改文档、加固件文件都会让
  # kernel / initrd / boot.img 全部重算（2026-11-21 实测：把 7 个 a660 固件提交
  # 进 git，内核因此重编 5 分钟，boot.img md5 变了，得重新刷机）。
  venusKernelTree = builtins.filterSource (
    path: type:
    let
      base = baseNameOf path;
    in
    !(type == "directory" && base == "initramfs")
    && !(type == "regular" && lib.elem base [ "mkbootimg.py" "panel-venus-k2-test.c" "star-reference.dts" ])
    && !(type == "regular" && builtins.match ".*\\.o" base != null)
  ) ../kernel/venus;

  buildPkgs = pkgs.buildPackages;

  applyScript = buildPkgs.writeText "apply-kernel-patches.sh" (builtins.readFile ../tools/apply-kernel-patches.sh);

  patchset = buildPkgs.runCommand "venus-patchset" { } ''
    mkdir -p $out/tools $out/kernel
    cp ${applyScript} $out/tools/apply-kernel-patches.sh
    cp -r ${venusKernelTree} $out/kernel/venus
  '';

  src = buildPkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-${version}.tar.xz";
    hash = "sha256-A5rvhPKwmUrto/T8/D0C7J16m7uQIOomTEP0Rshg9gY=";
  };

  # 打好补丁、装好板级 DTS 的内核源码树。boot.img 里的 DTB 也从这棵树编，
  # 保证 DTB 与内核同源（fleet 用预编译内核包，闭包里没有 dtbs/）。
  patchedSrc = buildPkgs.runCommand "linux-venus-${version}-src" {
    nativeBuildInputs = [ buildPkgs.python3 ];
  } ''
    mkdir source
    tar xf ${src} --strip-components=1 -C source
    cd source
    export KSRC=$PWD
    bash ${patchset}/tools/apply-kernel-patches.sh
    cp ${patchset}/kernel/venus/sm8350-xiaomi-venus.dts arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dts
    sed -i '/sm8350-xiaomi-venus.dtb/d' arch/arm64/boot/dts/qcom/Makefile
    printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= sm8350-xiaomi-venus.dtb\n' >> arch/arm64/boot/dts/qcom/Makefile
    cd ..
    mv source $out
  '';
in
{
  inherit version src patchset patchedSrc;
}
