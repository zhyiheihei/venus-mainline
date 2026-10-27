#!/usr/bin/env bash
# 打包 venus 的 boot.img：Image.gz + venus.dtb + NixOS 官方 initrd(注入 preinit)
#
# 用法: tools/make-bootimg.sh <输出镜像路径> [内核 cmdline 附加项...]
# 前置: 设备在线(WiFi ssh 可达)，用它的 /run/current-system/initrd 作为 ramdisk；
#       缓存放在 ~/.cache/venus-kernel/nixos-initrd.bin，可用 REFRESH=1 强制刷新。
set -euo pipefail
out=${1:?'usage: make-bootimg.sh <out.img> [extra cmdline...]'}
shift || true
extra="$*"

here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
kdir=$HOME/.cache/venus-kernel
build=$kdir/linux-build
cache=$kdir/nixos-initrd.bin
work=$kdir/bootimg-work

mkdir -p "$kdir" "$work"

# 1) 内核 + DTB（先把仓库里的 DTS 同步进内核树，避免用到旧副本）
echo "== 编内核/DTB =="
cp "$root/kernel/venus/sm8350-xiaomi-venus.dts" \
   "$kdir/linux-7.2.6/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dts"
( cd "$root" && nix develop -c bash -c "cd '$build' && make ARCH=arm64 \
    CROSS_COMPILE=aarch64-unknown-linux-gnu- -j\$(nproc) Image dtbs" ) 2>&1 | grep -E 'OBJCOPY|DTC|error' | tail -3 || true

# 2) NixOS initrd（带缓存）
if [ "${REFRESH:-0}" = "1" ] || [ ! -s "$cache" ]; then
  echo "== 从设备取 NixOS initrd =="
  ssh venus "cp \$(readlink -f /nix/var/nix/profiles/system/initrd) /tmp/nixos-initrd.bin"
  "$here/vpull.sh" /tmp/nixos-initrd.bin "$work" >/dev/null
  mv -f "$work/nixos-initrd.bin" "$cache"
fi

# 3) 直接用 NixOS 官方 initrd（systemd stage-1），不再解包/注入/重打包。
#    NixOS 的 initrd 是 zstd cpio；内核 CONFIG_RD_ZSTD=y，可以直接给 mkbootimg。
echo "== 使用 NixOS 官方 initrd =="
cp -f "$cache" "$work/initrd.cpio.zst"

# 4) 拼接 + mkbootimg
echo "== mkbootimg =="
gzip -9 -c "$build/arch/arm64/boot/Image" > "$work/Image.gz"
cat "$work/Image.gz" "$build/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dtb" > "$work/Image.gz-dtb"

cmdline="console=tty0 console=ttyGS0,115200 init=/nix/var/nix/profiles/system/init boot.shell_on_fail \
net.ifnames=0 loglevel=7 firmware_class.path=/run/current-system/firmware \
regulator_ignore_unused pd_ignore_unused clk_ignore_unused $extra"

PYTHONPATH=$HOME/.cache/mkbootimg python3 "$HOME/.cache/mkbootimg/mkbootimg.py" \
  --header_version 1 --kernel "$work/Image.gz-dtb" --ramdisk "$work/initrd.cpio.zst" \
  --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --os_version 14.0.0 --os_patch_level 2099-12 \
  --cmdline "$cmdline" --output "$out" 2>&1 | tail -1

ls -l "$out" | awk '{print "生成:", $9, $5, "字节"}'
md5sum "$out" | cut -c1-32
