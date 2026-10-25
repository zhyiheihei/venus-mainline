#!/usr/bin/env bash
# 通过本机 /dev/ttyACM0 以 root(空密码)登录并执行命令。
# 用法: tools/serial-login.sh "<命令>" [等待秒]
set -euo pipefail
cmd=${1:?'usage: serial-login.sh "<command>" [sec]'}
sec=${2:-10}
dev=${VENUS_TTY:-/dev/ttyACM0}
[ -e "$dev" ] || { echo "ERR: $dev 不在"; exit 1; }
stty -F "$dev" 115200 cs8 -cstopb -parenb -crtscts raw -echo 2>/dev/null || true
timeout 1 cat "$dev" >/dev/null 2>&1 || true
printf 'root\n' > "$dev"; sleep 1
printf '\n' > "$dev";    sleep 1
printf '%s\n' "$cmd" > "$dev"
timeout "$sec" cat "$dev" 2>/dev/null | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tail -40
