#!/usr/bin/env bash
# 通过本机 /dev/ttyACM0（手机的 USB CDC-ACM 控制台）执行一条命令。
# 用法: tools/serial.sh "<命令>" [等待秒]
set -euo pipefail
cmd=${1:?'usage: serial.sh "<command>" [sec]'}
sec=${2:-10}
dev=${VENUS_TTY:-/dev/ttyACM0}
[ -e "$dev" ] || { echo "ERR: $dev 不在（手机没跑自建内核？）"; exit 1; }
stty -F "$dev" 115200 cs8 -cstopb -parenb -crtscts raw -echo 2>/dev/null || true
# 丢掉旧数据, 发命令, 收集输出
timeout 1 cat "$dev" > /dev/null 2>&1 || true
printf '%s\n' "$cmd" > "$dev"
timeout "$sec" cat "$dev" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tail -40
