#!/usr/bin/env bash
# Windows 侧设备状态：fastboot 设备 / VID_18D1 / COM 口
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
win() { ( cd "$here/.." && timeout 120 env -u SSH_AUTH_SOCK bash tools/win.sh "$1" 2>&1 | tr -d '\r' ); }

echo "== fastboot =="
win "fastboot devices"

echo "== USB 枚举 =="
win "powershell -NoProfile -Command \"'18D1=' + (Get-CimInstance Win32_PnPEntity | Where-Object {\$_.DeviceID -like '*VID_18D1*'} | Measure-Object).Count; 'COM=' + (Get-CimInstance Win32_SerialPort | Measure-Object).Count; (Get-CimInstance Win32_SerialPort | ForEach-Object { \$_.DeviceID + ' ' + \$_.Name }) -join '|'\""
