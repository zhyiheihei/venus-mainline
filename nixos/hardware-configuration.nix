# venus 的硬件描述（原文件由设备上的 nixos-generate-config 生成，只在设备上，
# 不进 git；换机后按安装时的实际布局重建，内容与旧的一致：根 = userdata 上的 ext4）。
{ lib, ... }:
{
  # 根文件系统落在 sda34/userdata，装的时候用 mkfs.ext4 -L nixos 打标签
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  # 手机没有 swap，也不用 zram（内存够，避免额外变量）
  swapDevices = [ ];
}
