# venus 的文件系统布局：与 nixos-config 里其它 fleet 主机（opi5p / nanopi-r5c）一致，
# 不使用 ext4 —— "/" 是 tmpfs，"/nix" 是独立 btrfs（label NIXOS_NIX，根目录即 store），
# 持久化数据在 /nix/persistent。
{ lib, ... }:
{
  fileSystems."/" = {
    device = "tmpfs";
    fsType = "tmpfs";
    options = [
      "mode=755"
      "nodev"
      "nosuid"
      "relatime"
      "size=80%"
    ];
  };

  fileSystems."/nix" = {
    device = "/dev/disk/by-label/NIXOS_NIX";
    fsType = "btrfs";
    neededForBoot = true;
    options = [
      "compress-force=zstd"
      "autodefrag"
      "nosuid"
      "nodev"
    ];
  };

  swapDevices = [ ];
}
