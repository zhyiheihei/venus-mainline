#!/usr/bin/env bash
# 把 NixOS 闭包打成 venus 用的 btrfs userdata 镜像（label NIXOS_NIX，根目录即 store）。
# 用法: tools/mkbtrfs-img.sh <closure> <out.simg> [--size 8G] [--hostkey <file>]
#   产物是 sparse 镜像（img2simg），直接 fastboot flash userdata 用。
#   需要 sudo（loop mount），中间 raw 镜像落在磁盘（默认 ~/.cache/venus-k27），不落 /tmp（tmpfs）。
set -euo pipefail

closure=${1:?'usage: mkbtrfs-img.sh <closure> <out.simg> [--size 8G] [--hostkey <file>]'}
out=${2:?'usage: mkbtrfs-img.sh <closure> <out.simg> [--size 8G] [--hostkey <file>]'}
shift 2
size=8G
hostkey=""
while [ $# -gt 0 ]; do
  case $1 in
    --size) size=$2; shift 2;;
    --hostkey) hostkey=$2; shift 2;;
    *) echo "unknown arg $1" >&2; exit 1;;
  esac
done

[ -e "$closure/init" ] || { echo "闭包不存在: $closure" >&2; exit 1; }

disk=${VENUS_IMG_WORK:-$HOME/.cache/venus-k27}
mkdir -p "$disk"
raw=$disk/$(basename "$out" .simg).raw
stage=$disk/.stage.$$
mnt=$disk/.mnt.$$

cleanup() {
  sudo umount "$mnt" 2>/dev/null || true
  rm -rf "$stage" "$mnt"
}
trap cleanup EXIT

rm -f "$raw"; rm -rf "$stage"; mkdir -p "$stage" "$mnt"
truncate -s "$size" "$raw"
mkfs.btrfs -q -L NIXOS_NIX -f "$raw"

sudo mount -o loop "$raw" "$mnt"

nix copy --no-check-sigs --to "local?root=$stage" "$closure" >/dev/null
# btrfs 根目录就是 /nix，所以 store 要直接落在根目录下（$mnt/store），不能放进 $mnt/nix。
sudo mv "$stage"/nix/* "$mnt"/
[ -e "$mnt/store/$(basename "$closure")" ] || { echo "✗ store 未写入镜像: $mnt/store/$(basename "$closure")" >&2; exit 1; }

sudo mkdir -p "$mnt/var/nix/profiles" "$mnt/persistent/etc/ssh"
sudo ln -sfn "$closure" "$mnt/var/nix/profiles/system"
if [ -n "$hostkey" ] && [ -f "$hostkey" ]; then
  sudo install -m 0600 "$hostkey" "$mnt/persistent/etc/ssh/ssh_host_ed25519_key"
fi

sudo umount "$mnt"

img2simg "$raw" "$out"
echo "out=$out size=$(stat -c %s "$out") md5=$(md5sum "$out" | cut -c1-32)"
echo "raw=$raw ($(stat -c %s "$raw") 字节, $size)"
echo "closure=$closure"
echo "store 条目=$(nix-store -qR "$closure" | wc -l)"
