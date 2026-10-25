#!/usr/bin/env bash
# 大文件推送: 设备侧监听 9500, 主机经 9310 主动发送(实测 12MB 稳定)。
# 用法: tools/vpush-big.sh <本地文件> <手机路径>
set -euo pipefail
src=${1:?'usage: vpush-big.sh <local> <remote>'}
dst=${2:?'usage: vpush-big.sh <local> <remote>'}
here=$(cd "$(dirname "$0")" && pwd)
size=$(stat -c%s "$src"); md5=$(md5sum "$src" | cut -d' ' -f1)
"$here/vcmd.sh" "nc -l -p 9500 > $dst &" 2 >/dev/null 2>&1 || true
sleep 3
timeout 300 nc -N -w 5 <LAN_WINDOWS_IP> 9310 < "$src" || true
sleep 1
"$here/vcmd.sh" "md5sum $dst; wc -c < $dst" 6 | tail -3
echo "本机: $size 字节 md5=$md5"
