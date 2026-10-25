#!/usr/bin/env bash
# 把本地文件/目录推到手机（走 WiFi：tar over ssh，设备侧用 busybox tar）。
# 用法: tools/vpush.sh <本地路径> <手机上的目标目录或文件名>
set -euo pipefail
src=${1:?'usage: vpush.sh <local> <remote>'}
dst=${2:?'usage: vpush.sh <local> <remote>'}
src=$(readlink -f "$src")
base=$(basename "$src")
dir=$(dirname "$src")
# 目录: 直接放进 dst; 文件: 若 dst 是目录(或以 / 结尾)则放进, 否则当作目标文件名
if [ -d "$src" ]; then
  tar -C "$src" -cf - . | timeout 1800 ssh venus "mkdir -p '$dst' && tar -xf - -C '$dst'"
  echo "已推送目录 -> venus:$dst"
elif [[ "$dst" == */ ]] || ssh venus "test -d '$dst'" 2>/dev/null; then
  tar -C "$dir" -cf - "$base" | timeout 1800 ssh venus "mkdir -p '$dst' && tar -xf - -C '$dst'"
  echo "已推送 -> venus:$dst/$base"
else
  tdir=$(dirname "$dst")
  if [ "$tdir/$base" = "$dst" ]; then
    tar -C "$dir" -cf - "$base" | timeout 1800 ssh venus "mkdir -p '$tdir' && tar -xf - -C '$tdir'"
  else
    tar -C "$dir" -cf - "$base" | timeout 1800 ssh venus "mkdir -p '$tdir' && tar -xf - -C '$tdir' && mv -f '$tdir/$base' '$dst'"
  fi
  echo "已推送 -> venus:$dst"
fi
