#!/usr/bin/env bash
# venus 装机/更新流水线（2026-11-09 实测跑通的那条路，逐步可单独跑）
#
#   tools/install-venus.sh dtb       编译 DTB（含 memory 占位修正）
#   tools/install-venus.sh bootimg   打 boot.img（v1 + Image.gz + venus.dtb + NixOS initrd）
#   tools/install-venus.sh rootfs    生成 userdata 用的 12GiB ext4 稀疏镜像
#   tools/install-venus.sh flash     经 Windows 主机刷 boot_b / dtbo_b / userdata
#   tools/install-venus.sh deploy    走 WiFi 把新闭包 copy 过去并 switch（不刷机）
#   tools/install-venus.sh all       dtb + bootimg + rootfs
#
# 覆盖用环境变量：KERNEL_BUILD / WORK / BUILD_ROOT / PHONE_IP
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)

KERNEL_BUILD=${KERNEL_BUILD:-$HOME/.cache/venus-kernel/linux-build}
WORK=${WORK:-$HOME/.cache/venus-install}
BUILD_ROOT=${BUILD_ROOT:-$HOME/.cache/venus-build}
PHONE_IP=${PHONE_IP:-192.168.0.150}
IMG_SIZE=${IMG_SIZE:-12G}
NIXSRC=${NIXSRC:-$root/kernel/linux-7.2.6}
DTB_SRC=$root/kernel/venus/sm8350-xiaomi-venus.dts
DTB=$KERNEL_BUILD/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dtb

# 本机 /tmp 是 tmpfs（内存盘），往那里写 12GiB 镜像会直接把整机 OOM。
require_disk_backed() {
  local p=$1
  while [ ! -e "$p" ] && [ "$p" != "/" ]; do p=$(dirname "$p"); done
  local t; t=$(stat -f -c %T "$p" 2>/dev/null || echo unknown)
  case $t in
    tmpfs|ramfs) echo "$p 在 $t 上（内存盘），写 12GiB 镜像会把整机 OOM；换到磁盘路径" >&2; exit 1 ;;
  esac
}

case ${1:-all} in rootfs|flash|all) require_disk_backed "$WORK" ;; esac

# cache.zhyi.xin 已死，留着会让每个 store path 空等 60s
export NIX_CONFIG="substituters = http://192.168.0.56:13851 https://cache.nixos.org https://cache.lantian.pub/lantian https://lab.opi5p.zhyi.xin/nix-static-file-cache
connect-timeout = 5"

closure() {
  nix build --no-link --print-out-paths --override-input nixpkgs \
    'https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz' \
    "path:$BUILD_ROOT#nixosConfigurations.venus.config.system.build.$1"
}

stage_dtb() {
  cp "$DTB_SRC" "$NIXSRC/arch/arm64/boot/dts/qcom/sm8350-xiaomi-venus.dts"
  nix develop "$root" -c make -C "$NIXSRC" O="$KERNEL_BUILD" ARCH=arm64 \
    CROSS_COMPILE=aarch64-unknown-linux-gnu- dtbs
  echo "DTB: $DTB ($(stat -c %s "$DTB") 字节)"
}

stage_bootimg() {
  local initrd; initrd=$(nix eval --raw --override-input nixpkgs \
    'https://channels.nixos.org/nixos-25.05/nixexprs.tar.xz' \
    "path:$BUILD_ROOT#nixosConfigurations.venus.config.system.build.initialRamdisk.outPath")
  KERNEL_IMAGE=$root/nixos/kernel/Image DTB=$DTB INITRD=$initrd/initrd \
    "$here/make-bootimg.sh" "${1:-$WORK/boot-venus.img}"
}

stage_rootfs() {
  local out=$WORK/root
  mkdir -p "$out"
  local sys; sys=$(closure toplevel)
  echo "闭包: $sys"
  nix copy --no-check-sigs --to "local?root=$out" "$sys"
  local p=$out/nix/var/nix/profiles
  ln -sfn "$sys" "$p/system-link"; ln -sfn system-link "$p/system"
  mkdir -p "$out/etc/nixos"
  cp "$BUILD_ROOT"/nixos/configuration.nix "$BUILD_ROOT"/nixos/hardware-configuration.nix \
     "$BUILD_ROOT"/nixos/kmods-package.nix "$out/etc/nixos/"
  cp -r "$BUILD_ROOT"/nixos/firmware "$out/etc/nixos/" 2>/dev/null || true

  # 属主必须是 root:root —— 否则 NetworkManager 会以 "file has invalid owner"
  # 跳过 wifi 插件，表现为 wlan0 起来但拿不到地址
  sudo chown -R 0:0 "$out"

  rm -f "$WORK/rootfs.img" "$WORK/rootfs.simg"
  truncate -s "$IMG_SIZE" "$WORK/rootfs.img"
  sudo mkfs.ext4 -q -F -L nixos -m 1 "$WORK/rootfs.img"
  sudo mkdir -p /tmp/mnt-venus
  sudo mount -o loop "$WORK/rootfs.img" /tmp/mnt-venus
  sudo cp -a "$out"/. /tmp/mnt-venus/
  [ "$(sudo stat -c %u:%g /tmp/mnt-venus/nix)" = "0:0" ] || { echo "属主修失败" >&2; exit 1; }
  sync
  sudo umount /tmp/mnt-venus
  nix shell nixpkgs#android-tools -c img2simg "$WORK/rootfs.img" "$WORK/rootfs.simg"
  echo "rootfs.simg: $(stat -c %s "$WORK/rootfs.simg") 字节"
}

stage_flash() {
  local w=$WORK
  # dtbo_b 必须写零（erase 也行，但 Linaro 建议写零），否则 ABL 用 dtbo 里的 DTB
  [ -f "$w/dtbo-zero.img" ] || nix shell nixpkgs#coreutils -c \
    sh -c "head -c 25165824 /dev/zero > '$w/dtbo-zero.img'"
  local user; user=$(cut -d@ -f1 ~/.config/mi11/win-host)
  for f in boot-venus.img dtbo-zero.img rootfs.simg; do
    scp -o BatchMode=yes -o LogLevel=ERROR "$w/$f" "$user@$(cut -d@ -f2 ~/.config/mi11/win-host):/Users/$user/mi11/$f"
  done
  "$here/win.sh" "fastboot flash boot_b boot-venus.img"
  "$here/win.sh" "fastboot flash dtbo_b dtbo-zero.img"
  "$here/win.sh" "fastboot flash userdata rootfs.simg"   # 12 片稀疏，约 5 分钟
  "$here/win.sh" "fastboot set_active b"
  "$here/win.sh" "fastboot reboot"
}

stage_deploy() {
  local sys; sys=$(closure toplevel)
  nix copy --no-check-sigs --to ssh://root@"$PHONE_IP" "$sys"
  ssh "root@$PHONE_IP" "nix-env -p /nix/var/nix/profiles/system --set '$sys' \
    && '$sys'/bin/switch-to-configuration switch"
}

case ${1:-all} in
  dtb) stage_dtb ;;
  bootimg) stage_bootimg "${2:-$WORK/boot-venus.img}" ;;
  rootfs) stage_rootfs ;;
  flash) stage_flash ;;
  deploy) stage_deploy ;;
  all) stage_dtb && stage_bootimg "${2:-$WORK/boot-venus.img}" && stage_rootfs ;;
  *) sed -n '2,15p' "$0"; exit 1 ;;
esac
