#!/usr/bin/env bash
# 仅用串口把一个小文件写到手机上(命令通道不可用时的救援手段)。
# 用法: tools/serial-put.sh <本地文件> <手机路径>
set -euo pipefail
src=${1:?'usage: serial-put.sh <local> <remote>'}
dst=${2:?'usage: serial-put.sh <local> <remote>'}
here=$(cd "$(dirname "$0")" && pwd)
b64=$(base64 -w0 "$src")
md5=$(md5sum "$src" | cut -d' ' -f1)
"$here/serial-login.sh" "echo $b64 | base64 -d > $dst; chmod +x $dst; md5sum $dst" 14 2>&1 | tail -3
echo "期望 md5=$md5"
