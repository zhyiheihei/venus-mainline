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
  ssh venus "cp /run/current-system/initrd /tmp/nixos-initrd.bin"
  "$here/vpull.sh" /tmp/nixos-initrd.bin "$work" >/dev/null
  mv -f "$work/nixos-initrd.bin" "$cache"
fi

# 3) 解包 -> 注入 preinit -> 重打包
echo "== 注入 preinit =="
rm -rf "$work/ird" 2>/dev/null || true; mkdir -p "$work/ird"
( cd "$work/ird" && zstd -dc "$cache" 2>/dev/null | cpio -id --no-absolute-filenames --quiet 2>/dev/null )
stage1=$(readlink "$work/ird/init")
eu=$(ls -d "$work/ird"/nix/store/*extra-utils* 2>/dev/null | head -1)
[ -n "$eu" ] || { echo "initrd 里找不到 extra-utils" >&2; exit 1; }
eu_rel=${eu#"$work/ird"}

cat > "$work/ird/venus-preinit.sh" <<EOS
#! $eu_rel/bin/ash
# venus preinit: 先建 USB ACM 串口(让 console=ttyGS0 挂得上)，再原样交给 NixOS stage-1
export PATH=$eu_rel/bin
export LD_LIBRARY_PATH=$eu_rel/lib

mkdir -p /proc /sys /dev 2>/dev/null
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /sys/kernel/config /dev/pts
mount -t configfs none /sys/kernel/config 2>/dev/null
mount -t devpts devpts /dev/pts 2>/dev/null

UDC=\$(ls /sys/class/udc 2>/dev/null | head -1)
if [ -n "\$UDC" ]; then
  G=/sys/kernel/config/usb_gadget/venus
  mkdir -p "\$G" "\$G/strings/0x409" "\$G/configs/c.1/strings/0x409" 2>/dev/null
  echo 0x18d1 > "\$G/idVendor"; echo 0x4ee1 > "\$G/idProduct"
  echo 0x0100 > "\$G/bcdDevice"; echo 0x0200 > "\$G/bcdUSB"
  echo venus-m1 > "\$G/strings/0x409/serialnumber"
  echo Xiaomi > "\$G/strings/0x409/manufacturer"
  echo venus > "\$G/strings/0x409/product"
  echo ACM > "\$G/configs/c.1/strings/0x409/configuration"
  echo 250 > "\$G/configs/c.1/MaxPower"
  mkdir -p "\$G/functions/acm.GS0"
  ln -sf "\$G/functions/acm.GS0" "\$G/configs/c.1/acm.GS0" 2>/dev/null
  echo "\$UDC" > "\$G/UDC" 2>/dev/null
  sleep 1
fi

# 固件搜索路径（NixOS 的 .zst 固件在 /run/current-system/firmware）
echo /run/current-system/firmware > /sys/module/firmware_class/parameters/path 2>/dev/null

# 自愈: 根文件系统上的 /init
mkdir -p /fixroot
if mount -t ext4 /dev/sda34 /fixroot 2>/dev/null; then
  [ -e /fixroot/init ] || { ln -sfn /nix/var/nix/profiles/system/init /fixroot/init; sync; }
  umount /fixroot 2>/dev/null
fi

if [ -c /dev/ttyGS0 ]; then
  exec >/dev/ttyGS0 2>&1 </dev/ttyGS0
  echo
  echo "=== VENUS preinit: udc=\$UDC -> NixOS stage-1 ==="
fi

exec $stage1
EOS
chmod +x "$work/ird/venus-preinit.sh"
rm -f "$work/ird/init" 2>/dev/null || true; ln -s /venus-preinit.sh "$work/ird/init"
( cd "$work/ird" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 > "$work/initrd.cpio.gz" )

# 4) 拼接 + mkbootimg
echo "== mkbootimg =="
gzip -9 -c "$build/arch/arm64/boot/Image" > "$work/Image.gz"
cat "$work/Image.gz" "$build/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dtb" > "$work/Image.gz-dtb"

cmdline="console=ttyGS0,115200 init=/nix/var/nix/profiles/system/init boot.shell_on_fail \
net.ifnames=0 ignore_loglevel loglevel=4 firmware_class.path=/run/current-system/firmware \
regulator_ignore_unused pd_ignore_unused clk_ignore_unused $extra"

PYTHONPATH=$HOME/.cache/mkbootimg python3 "$HOME/.cache/mkbootimg/mkbootimg.py" \
  --header_version 1 --kernel "$work/Image.gz-dtb" --ramdisk "$work/initrd.cpio.gz" \
  --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --os_version 14.0.0 --os_patch_level 2099-12 \
  --cmdline "$cmdline" --output "$out" 2>&1 | tail -1

ls -l "$out" | awk '{print "生成:", $9, $5, "字节"}'
md5sum "$out" | cut -c1-32
