#!/usr/bin/env bash
# 不用 fastboot 更新内核: 走 USB 网络把 boot.img 推到手机, 手机自己 dd 到 boot_b 再重启。
# 用法: tools/update-kernel.sh <boot.img> [--reboot]
set -euo pipefail
img=${1:?'usage: update-kernel.sh <boot.img> [--reboot]'}
reboot_flag=${2:-}
here=$(cd "$(dirname "$0")" && pwd)

"$here/push.sh" "$here/_flashboot.sh" /tmp/flashboot.sh 9200 >/dev/null 2>&1 || true
"$here/push.sh" "$img" /tmp/boot.img 9201 | tail -2
"$here/ncsh.sh" "sh /tmp/flashboot.sh" 6000 | tail -4
if [ "$reboot_flag" = "--reboot" ]; then
  "$here/ncsh.sh" "reboot -f" 1500 >/dev/null 2>&1 || true
  echo "已触发重启, 等 25s"; sleep 25
fi
