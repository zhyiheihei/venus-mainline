#!/usr/bin/env bash
# fastboot 封装：本地超时 + Windows 侧清理残留进程
# fastboot 找不到设备会永久等待；超时后本地 ssh 被杀，但 Windows 上的 fastboot.exe
# 可能仍然活着，等设备一插上就把旧命令跑掉（已发生过）。因此每次调用前后都清理。
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
cmd=${1:-devices}
limit=${MI11_FB_TIMEOUT:-20}

killstale() {
  ( cd "$here/.." && timeout 30 env -u SSH_AUTH_SOCK bash tools/win.sh \
      "taskkill /IM fastboot.exe /F >nul 2>&1 & exit 0" >/dev/null 2>&1 )
}

killstale
out=$(mktemp)
( cd "$here/.." && timeout "$limit" env -u SSH_AUTH_SOCK bash tools/win.sh "fastboot $cmd" >"$out" 2>&1 )
rc=$?
killstale
sed -E 's/\r$//' "$out"

if [ $rc -eq 124 ]; then
  echo "fastboot 超时（${limit}s 无设备）：先 tools/win-probe.sh 确认 18D1" >&2
  rm -f "$out"; exit 2
fi
if [ "$cmd" = "devices" ] && [ ! -s "$out" ]; then
  echo "没有 fastboot 设备（USB 未枚举）：先 tools/win-probe.sh" >&2
  rm -f "$out"; exit 3
fi
rm -f "$out"
exit $rc
