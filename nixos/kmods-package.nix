/* 自建内核模块按标准布局打包：lib/modules/7.2.6/{kernel,extra}/...
 *
 * 交给 boot.kernelPackages.kernel 后：
 *   - /lib/modules/7.2.6 完整（614 个模块 + modules.dep），modprobe / udev 自动加载都能用
 *   - boot.initrd.kernelModules 里的模块会被打进 initrd（早期点亮面板）
 * 内核镜像 Image 另由 tools/make-bootimg.sh 打进 boot.img。
 */
{ pkgs, lib, ... }:

let
  version = "7.2.6";
  artifacts = ./kernel;
in
pkgs.runCommandLocal "linux-venus-${version}" { } ''
  install -Dm644 ${artifacts}/Image $out/Image
  mkdir -p $out/lib/modules/${version}
  cp -r ${artifacts}/mod/. $out/lib/modules/${version}/
  for f in modules.order modules.builtin modules.builtin.modinfo; do
    [ -f ${artifacts}/$f ] && install -m644 ${artifacts}/$f $out/lib/modules/${version}/$f || true
  done
  ${pkgs.kmod}/bin/depmod -a -b $out ${version}
''
