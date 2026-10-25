#!/usr/bin/env bash
# 从手机取文件/目录到本机（走 WiFi：tar over ssh）。
# 用法: tools/vpull.sh <手机路径> <本地目标目录>
set -euo pipefail
src=${1:?'usage: vpull.sh <remote> <local>'}
dst=${2:?'usage: vpull.sh <remote> <local>'}
base=$(basename "$src")
dir=$(dirname "$src")
mkdir -p "$dst"
timeout 1800 ssh venus "tar -C '$dir' -cf - '$base'" | tar -xf - -C "$dst"
echo "已取回 -> $dst/$base"
