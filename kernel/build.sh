#!/usr/bin/env bash
# venus mainline 内核构建 + boot.img 打包(M1)
# 在 nix develop 内运行;产物:venus-boot.img(拷回项目目录)
#
# 构建工作区放 ~/.cache/venus-kernel(本地 btrfs):~/Documents 是 FUSE,
# 高并发编译会在 FUSE 层报随机 EMFILE/ENFILE(「打开的文件过多」)。
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(pwd)

K=linux-7.2.6
WORK="$HOME/.cache/venus-kernel"
OUT="$WORK/linux-build"
ARCH=arm64
CC=aarch64-unknown-linux-gnu-

# 0. 工作区:解压源码(仅首次,后续复用做增量编译)
mkdir -p "$WORK"
if [ ! -d "$WORK/$K" ]; then
	tar xf "$ROOT/$K.tar.xz" -C "$WORK"
fi

# 1. 注入 venus DTS(先清残留再追加,幂等)
cp venus/sm8350-xiaomi-venus.dts "$WORK/$K/arch/arm64/boot/dts/qcom/"
sed -i '/sm8350-xiaomi-venus.dtb/d' "$WORK/$K/arch/arm64/boot/dts/qcom/Makefile"
printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= sm8350-xiaomi-venus.dtb\n' >> \
	"$WORK/$K/arch/arm64/boot/dts/qcom/Makefile"

# 2. busybox(static aarch64,Alpine 官方静态包,已入库)
if [ ! -x busybox-aarch64 ]; then
	echo "missing kernel/busybox-aarch64" >&2; exit 1
fi

# 3. initramfs 布局(本地盘)
rm -rf "$WORK/initramfs"
mkdir -p "$WORK/initramfs"/{bin,sbin,dev,proc,sys,tmp,run,etc}
cp busybox-aarch64 "$WORK/initramfs/bin/busybox" && chmod 755 "$WORK/initramfs/bin/busybox"
ln -sf busybox "$WORK/initramfs/bin/sh"
cp venus/initramfs/init "$WORK/initramfs/init" && chmod 755 "$WORK/initramfs/init"

# 4. 配置:defconfig 起步 + bring-up 关键项(builtin,内嵌 initramfs 直接可用)
make -C "$WORK/$K" O="$OUT" ARCH=$ARCH defconfig
"$WORK/$K/scripts/config" --file "$OUT/.config" \
	-e USB_CONFIGFS -e USB_F_NCM -e USB_F_ACM -e CONFIGFS_FS \
	-e USB_DWC3 -e USB_DWC3_QCOM \
	-e SCSI_UFSHCD -e SCSI_UFS_QCOM \
	-e EXT4_FS \
	-e PSTORE -e PSTORE_RAM \
	-e DEVTMPFS -e DEVTMPFS_MOUNT \
	-e BLK_DEV_INITRD -e RD_GZIP \
	--set-str CONFIG_INITRAMFS_SOURCE "$WORK/initramfs"
make -C "$WORK/$K" O="$OUT" ARCH=$ARCH olddefconfig

# 5. 编译(降并发规避偶发资源竞争;诊断 fd 水位)
ulimit -n
cat /proc/sys/fs/file-nr
make -C "$WORK/$K" O="$OUT" ARCH=$ARCH CROSS_COMPILE="$CC" -j"${MAKE_JOBS:-10}" Image dtbs

# 6. 打包 boot.img(v4,内嵌 initramfs,无外部 ramdisk)
gzip -9kf "$OUT/arch/arm64/boot/Image"
MKBOOTIMG="$HOME/.cache/mkbootimg/mkbootimg.py"
[ -f "$MKBOOTIMG" ] || git clone --depth 1 \
	https://android.googlesource.com/platform/system/tools/mkbootimg \
	"$HOME/.cache/mkbootimg"
PYTHONPATH="$HOME/.cache/mkbootimg" python3 "$MKBOOTIMG" \
	--header_version 4 \
	--kernel "$OUT/arch/arm64/boot/Image.gz" \
	--dtb "$OUT/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dtb" \
	--os_version 12 --os_patch_level 2022-05-05 \
	--cmdline "clk_ignore_unused pd_ignore_unused rdinit=/init" \
	--output "$ROOT/venus-boot.img"

cp "$OUT/.config" "$ROOT/venus.config.snapshot"
ls -la "$ROOT/venus-boot.img"
