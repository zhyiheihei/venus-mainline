#!/usr/bin/env bash
# 从手机取文件/目录到本机（走 WiFi：tar over ssh）。
# 用法: tools/vpull.sh <手机路径> <本地目标目录>    （VENUS_IP 默认 192.168.0.68）
# 整个 /nix/persistent 请用 tools/fetch-logs.sh。

set -euo pipefail
ip=${VENUS_IP:-192.168.0.68}
src=${1:?'usage: vpull.sh <remote> <local>'}
dst=${2:?'usage: vpull.sh <remote> <local>'}
base=$(basename "$src")
dir=$(dirname "$src")
mkdir -p "$dst"
timeout 1800 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=ERROR -o IdentityAgent=none root@"$ip" "tar -C '$dir' -cf - '$base'" | tar -xf - -C "$dst"
echo "已取回 -> $dst/$base"
