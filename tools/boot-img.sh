#!/usr/bin/env bash
# 从 NixOS 闭包组装 boot.img（内核 / DTB / initrd / cmdline 全部取自同一闭包）
# 用法: boot-img.sh <closure> <out.img> [--dtb <dtb 文件>]
set -euo pipefail
closure=${1:?'usage: boot-img.sh <closure> <out.img> [--dtb <dtb>]'}
out=${2:?'usage: boot-img.sh <closure> <out.img> [--dtb <dtb>]'}
shift 2
dtb=""
while [ $# -gt 0 ]; do
  case $1 in
    --dtb) dtb=$2; shift 2;;
    *) echo "unknown arg $1" >&2; exit 1;;
  esac
done

[ -e "$closure/init" ] || { echo "闭包不存在: $closure" >&2; exit 1; }
[ -e "$closure/kernel" ] || { echo "闭包缺 kernel: $closure" >&2; exit 1; }
[ -e "$closure/initrd" ] || { echo "闭包缺 initrd: $closure" >&2; exit 1; }

dtb=${dtb:-$closure/dtbs/qcom/sm8350-xiaomi-venus.dtb}
[ -e "$dtb" ] || { echo "DTB 不存在: $dtb" >&2; exit 1; }

cmdline="console=ttyGS0,115200 console=tty0 loglevel=7 consoleblank=0 root=fstab init=$closure/init firmware_class.path=/run/current-system/firmware regulator_ignore_unused pd_ignore_unused clk_ignore_unused net.ifnames=0"

work=$(mktemp -d "${TMPDIR:-/tmp}/venus-bootimg.XXXXXX")
trap 'rm -rf "$work"' EXIT

gzip -9 -n -c "$(readlink -f "$closure/kernel")" > "$work/k.gz"
cat "$work/k.gz" "$dtb" > "$work/kernel-dtb"

PYTHONPATH=$HOME/.cache/mkbootimg python3 "$HOME/.cache/mkbootimg/mkbootimg.py" \
  --header_version 2 \
  --kernel "$work/kernel-dtb" \
  --ramdisk "$(readlink -f "$closure/initrd")" \
  --dtb "$dtb" \
  --cmdline "$cmdline" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --dtb_offset 0x01f00000 --tags_offset 0x00000100 --pagesize 4096 \
  --os_version 14.0.0 --os_patch_level 2099-12 \
  -o "$out" >/dev/null

md5=$(md5sum "$out" | cut -c1-32)
echo "out=$out size=$(stat -c %s "$out") md5=$md5"
echo "closure=$closure"
echo "dtb=$dtb md5=$(md5sum "$dtb" | cut -c1-32)"
