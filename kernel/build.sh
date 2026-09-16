#!/usr/bin/env bash
# venus mainline 内核构建 + boot.img 打包(M1)
# 在 nix develop 内运行;产物:venus-boot.img
set -euo pipefail
cd "$(dirname "$0")"

K=linux-7.2.6
OUT=linux-build
ARCH=arm64
CC=aarch64-unknown-linux-gnu-
ROOT=$(pwd)

# 1. 注入 venus DTS(源码树不入 git,每次构建前重放)
cp venus/sm8350-xiaomi-venus.dts "$K/arch/arm64/boot/dts/qcom/"
grep -q "sm8350-xiaomi-venus.dtb" "$K/arch/arm64/boot/dts/qcom/Makefile" ||
	sed -i '/sm8350-sony-xperia-sagami-pdx215.dtb/a sm8350-xiaomi-venus.dtb' \
		"$K/arch/arm64/boot/dts/qcom/Makefile"

# 2. busybox(static aarch64)
if [ ! -x busybox-aarch64 ]; then
	nix build --no-link --print-out-paths \
		"github:NixOS/nixpkgs/nixos-unstable#legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.pkgsStatic.busybox" \
		-o result-busybox
	cp result-busybox/bin/busybox busybox-aarch64
fi

# 3. initramfs 布局
rm -rf initramfs
mkdir -p initramfs/{bin,sbin,dev,proc,sys,tmp,run,etc}
cp busybox-aarch64 initramfs/bin/busybox && chmod 755 initramfs/bin/busybox
ln -sf busybox initramfs/bin/sh
cp venus/initramfs/init initramfs/init && chmod 755 initramfs/init

# 4. 配置:defconfig 起步 + bring-up 关键项(builtin,内嵌 initramfs 直接可用)
make -C "$K" O="$OUT" ARCH=$ARCH defconfig
"$K/scripts/config" --file "$OUT/.config" \
	-e USB_CONFIGFS -e USB_F_NCM -e USB_F_ACM -e CONFIGFS_FS \
	-e USB_DWC3 -e USB_DWC3_QCOM \
	-e SCSI_UFSHCD -e SCSI_UFS_QCOM \
	-e EXT4_FS \
	-e PSTORE -e PSTORE_RAM \
	-e DEVTMPFS -e DEVTMPFS_MOUNT \
	-e BLK_DEV_INITRD -e RD_GZIP \
	--set-str CONFIG_INITRAMFS_SOURCE "$ROOT/initramfs" \
	--set-str CONFIG_INITRAMFS_COMPRESSION ".gz" 2>/dev/null || true
make -C "$K" O="$OUT" ARCH=$ARCH olddefconfig

# 5. 编译
make -C "$K" O="$OUT" ARCH=$ARCH CROSS_COMPILE="$CC" -j"$(nproc)" Image dtbs

# 6. 打包 boot.img(v4,内嵌 initramfs,无外部 ramdisk)
gzip -9kf "$OUT/arch/arm64/boot/Image"
if [ ! -f venus/mkbootimg.py ]; then
	echo "missing venus/mkbootimg.py" >&2; exit 1
fi
python3 venus/mkbootimg.py \
	--header_version 4 \
	--kernel "$OUT/arch/arm64/boot/Image.gz" \
	--dtb "$OUT/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dtb" \
	--os-version 12 --os-patch-level 2022-05-05 \
	--cmdline "clk_ignore_unused pd_ignore_unused rdinit=/init" \
	--output venus-boot.img

ls -la venus-boot.img
