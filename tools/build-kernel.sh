#!/usr/bin/env bash
# 内核构建（Image + modules + DTB）。产物直接用 tools/pack-kernel.sh 落到 nixos/kernel/。
#
#   tools/build-kernel.sh          # 增量
#   tools/build-kernel.sh --clean  # 扔掉构建目录重来
#
# 配置基线不是 defconfig，而是**设备上正在跑的 /proc/config.gz**（~/.cache/venus-kernel/device.config），
# 这样"改一个驱动"不会顺带把别的东西改掉。首次运行会用 ssh 从设备取一次。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
K=linux-7.2.6
WORK=${WORK:-$HOME/.cache/venus-kernel}
OUT=$WORK/linux-build
SRC=$WORK/$K
BASE=$WORK/device.config
ARCH=arm64
CC=aarch64-unknown-linux-gnu-
JOBS=${MAKE_JOBS:-$(nproc)}
PHONE_IP=${PHONE_IP:-192.168.0.150}

case ${1:-} in --clean) rm -rf "$OUT" ;; esac

[ -d "$SRC" ] || { echo "解压源码 → $SRC"; mkdir -p "$WORK"; tar xf "$root/kernel/$K.tar.xz" -C "$WORK"; }

# 基线配置：设备上正在跑的那份
if [ ! -f "$BASE" ]; then
  echo "== 从设备取 /proc/config.gz 作为基线"
  env -u SSH_AUTH_SOCK ssh -o BatchMode=yes -o IdentityAgent=none "root@$PHONE_IP" 'zcat /proc/config.gz' > "$BASE"
  [ -s "$BASE" ] || { echo "取配置失败" >&2; exit 1; }
fi

# 内核侧改动（面板/触摸/regulator/pcie/ath11k/dpu/battmgr），缺了这些 Image 就不完整
echo "== 应用内核补丁"
KSRC=$SRC "$here/apply-kernel-patches.sh" >/dev/null

cp "$root/kernel/venus/sm8350-xiaomi-venus.dts" "$SRC/arch/arm64/boot/dts/qcom/"
sed -i '/sm8350-xiaomi-venus.dtb/d' "$SRC/arch/arm64/boot/dts/qcom/Makefile"
printf 'dtb-$(CONFIG_ARCH_QCOM)\t+= sm8350-xiaomi-venus.dtb\n' >> "$SRC/arch/arm64/boot/dts/qcom/Makefile"

if [ ! -f "$OUT/.config" ]; then
  mkdir -p "$OUT"; cp "$BASE" "$OUT/.config"
fi

# 内嵌 initramfs：与能正常启动的形态保持一致
IR=$WORK/initramfs
if [ ! -x "$IR/bin/busybox" ] || [ ! -f "$IR/init" ]; then
  rm -rf "$IR"; mkdir -p "$IR"/{bin,sbin,dev,proc,sys,tmp,run,etc}
  cp "$root/kernel/busybox-aarch64" "$IR/bin/busybox"; chmod 755 "$IR/bin/busybox"
  ln -sf busybox "$IR/bin/sh"
  cp "$root/kernel/venus/initramfs/init" "$IR/init"; chmod 755 "$IR/init"
fi

echo "== 应用 config 项"
"$SRC/scripts/config" --file "$OUT/.config" \
  -e USB_CONFIGFS -e USB_F_NCM -e USB_F_ACM -e CONFIGFS_FS \
  -e USB_DWC3 -e USB_DWC3_QCOM \
  -e SCSI_UFSHCD -e SCSI_UFS_QCOM \
  -e EXT4_FS \
  -e PSTORE -e PSTORE_RAM \
  -e DEVTMPFS -e DEVTMPFS_MOUNT \
  -e BLK_DEV_INITRD -e RD_GZIP \
  `# --- USB OTG 接键鼠：HID 子系统 + pmic-glink 角色切换（对齐 sm8350-hdk）---` \
  -e HID_SUPPORT -e USB_ROLE_SWITCH \
  -m HID -m HID_GENERIC -m USB_HID -m USB_STORAGE \
  -m UCSI_PMIC_GLINK -m TYPEC_UCSI \
  -e INPUT_EVDEV \
  --set-str CONFIG_INITRAMFS_SOURCE "$IR"
make -C "$SRC" O="$OUT" ARCH=$ARCH olddefconfig

echo "== 编译 (-j$JOBS)"
make -C "$SRC" O="$OUT" ARCH=$ARCH CROSS_COMPILE="$CC" -j"$JOBS" Image modules dtbs

echo "== 打包到 nixos/kernel/"
"$here/pack-kernel.sh" "$OUT"
install -m644 "$OUT/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dtb" "$root/nixos/kernel/venus.dtb" 2>/dev/null || true

echo "== 完成: Image $(stat -c %s "$root/nixos/kernel/Image") 字节, 模块 $(find "$root/nixos/kernel/mod" -name '*.ko' | wc -l) 个"
