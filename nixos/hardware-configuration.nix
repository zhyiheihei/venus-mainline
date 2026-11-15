# venus 的硬件描述（原文件由设备上的 nixos-generate-config 生成）。
# 根 = userdata(sda34) 上的 ext4，安装时用 mkfs.ext4 -L nixos 打标签。
{ lib, ... }:
{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  # 手机没有 swap，也不用 zram
  swapDevices = [ ];
}
