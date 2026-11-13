#!/usr/bin/env bash
set -euo pipefail
out=${1:?'usage: make-bootimg.sh <out.img> [extra cmdline...]'}
shift || true
extra="$*"

here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
kdir=$HOME/.cache/venus-kernel
build=$kdir/linux-build
cache=$kdir/nixos-initrd.bin
work=$(mktemp -d "${TMPDIR:-/tmp}/venus-bootimg.XXXXXX")

mkdir -p "$kdir"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT

KERNEL_IMAGE=${KERNEL_IMAGE:-}
DTB=${DTB:-}
INITRD=${INITRD:-}

if [ -z "$KERNEL_IMAGE" ] || [ -z "$DTB" ]; then
  echo "== 编内核/DTB =="
  cp "$root/kernel/venus/sm8350-xiaomi-venus.dts" \
     "$kdir/linux-7.2.6/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dts"
  ( cd "$root" && nix develop -c bash -c "cd '$build' && make ARCH=arm64 \
      CROSS_COMPILE=aarch64-unknown-linux-gnu- -j\$(nproc) Image dtbs" ) 2>&1 | grep -E 'OBJCOPY|DTC|error' | tail -3 || true
fi
KERNEL_IMAGE=${KERNEL_IMAGE:-$build/arch/arm64/boot/Image}
DTB=${DTB:-$build/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dtb}

if [ -n "$INITRD" ]; then
  cache=$INITRD
elif [ "${REFRESH:-0}" = "1" ] || [ ! -s "$cache" ]; then
  echo "== 从设备取 NixOS initrd =="
  ssh venus "cp \$(readlink -f /nix/var/nix/profiles/system/initrd) /tmp/nixos-initrd.bin"
  "$here/vpull.sh" /tmp/nixos-initrd.bin "$work" >/dev/null
  mv -f "$work/nixos-initrd.bin" "$cache"
fi

echo "== 注入 preinit =="
rm -rf "$work/ird" 2>/dev/null || true; mkdir -p "$work/ird"
( cd "$work/ird" && zstd -dc "$cache" 2>/dev/null | cpio -id --no-absolute-filenames --quiet 2>/dev/null )
stage1=$(readlink "$work/ird/init")
eu=$(ls -d "$work/ird"/nix/store/*extra-utils* 2>/dev/null | head -1)
[ -n "$eu" ] || { echo "initrd 里找不到 extra-utils" >&2; exit 1; }
eu_rel=${eu#"$work/ird"}

cat > "$work/ird/venus-preinit.sh" <<EOS
export PATH=$eu_rel/bin
export LD_LIBRARY_PATH=$eu_rel/lib

mkdir -p /proc /sys /dev 2>/dev/null
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /sys/kernel/config /dev/pts
mount -t configfs none /sys/kernel/config 2>/dev/null
mount -t devpts devpts /dev/pts 2>/dev/null

for m in qcom-refgen-regulator cec drm_display_helper drm_dp_aux_bus drm_exec \
         drm_gpuvm gpu-sched mdt_loader ubwc_config msm panel-xiaomi-venus-k2; do
  modprobe "\$m" 2>/dev/null || true
done

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

echo /run/current-system/firmware > /sys/module/firmware_class/parameters/path 2>/dev/null

mkdir -p /fixroot
ROOTDEV=""
for d in /dev/sd*; do
  [ -b "\$d" ] || continue
  [ "\$(blkid -o value -s LABEL "\$d" 2>/dev/null)" = nixos ] && { ROOTDEV="\$d"; break; }
done
if mount -t ext4 "\${ROOTDEV:-none}" /fixroot 2>/dev/null; then
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
rm -rf "$work/ird/venus-fw"; mkdir -p "$work/ird/venus-fw/qca"
cp "$root"/nixos/firmware/qca/hpbtfw10.tlv "$root"/nixos/firmware/qca/hpbtfw21.tlv \
   "$root/nixos/firmware/qca/hpnv10."* "$work/ird/venus-fw/qca/" 2>/dev/null || true
for f in "$work/ird/venus-fw/qca/"hp*; do
  b=$(basename "$f"); cp "$f" "$work/ird/venus-fw/qca/wcn$b" 2>/dev/null || true
done

chmod +x "$work/ird/venus-preinit.sh"
rm -f "$work/ird/init" 2>/dev/null || true; ln -s /venus-preinit.sh "$work/ird/init"
( cd "$work/ird" && find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 > "$work/initrd.cpio.gz" )

echo "== mkbootimg =="
gzip -9 -c "$KERNEL_IMAGE" > "$work/Image.gz"
cat "$work/Image.gz" "$DTB" > "$work/Image.gz-dtb"

init_path=${INIT_PATH:-/nix/var/nix/profiles/system/init}
debug_params=""
if [ "${DEBUG:-0}" = "1" ]; then
  debug_params="loglevel=8 ignore_loglevel pstore.backend=ramoops oops=panic panic=30 printk.always_kmsg_dump=1 systemd.log_level=debug systemd.journald.forward_to_console=1 boot.shell_on_fail sysrq_always_enabled=1"
fi

cmdline="firmware_class.path=/venus-fw console=tty0 console=ttyGS0,115200 init=$init_path \
net.ifnames=0 loglevel=7 \
regulator_ignore_unused pd_ignore_unused clk_ignore_unused $debug_params $extra"

PYTHONPATH=$HOME/.cache/mkbootimg python3 "$HOME/.cache/mkbootimg/mkbootimg.py" \
  --header_version 1 --kernel "$work/Image.gz-dtb" --ramdisk "$work/initrd.cpio.gz" \
  --base 0x0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 --tags_offset 0x100 \
  --dtb_offset 0x1f00000 --os_version 14.0.0 --os_patch_level 2099-12 \
  --cmdline "$cmdline" --output "$out" 2>&1 | tail -1

ls -l "$out" | awk '{print "生成:", $9, $5, "字节"}'
md5sum "$out" | cut -c1-32
