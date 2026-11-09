# venus 自建内核（7.2.6 预编译产物）的可复用 recipe。
#
# artifacts 默认取仓库内 nixos/kernel/（本机由 tools/pack-kernel.sh 摆好）；
# 调用方可以传自己的路径或派生，这样别的仓库（例如 nixos-config 的 venus 主机）
# 能把同一个内核包接进自己的 kernelPackages / lantian.kernel。
{ pkgs, artifacts ? ./kernel, ... }:
(pkgs.callPackage ./kmods-package.nix { inherit artifacts; }).overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    modDirVersion = "7.2.6";
    version = "7.2.6";
    features = { };
    # NixOS 的 hardware.device-tree.enable 默认取 kernel.buildDTBs，
    # 自建包没这个属性会求值报错（我们不编 dtb，dtb 在打 boot.img 时用）
    buildDTBs = false;
  };
})
