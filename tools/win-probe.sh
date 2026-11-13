#!/usr/bin/env bash
# Windows 侧设备状态：fastboot / VID_18D1 / COM / 有问题的 USB 设备
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
win() { ( cd "$here/.." && timeout 150 env -u SSH_AUTH_SOCK bash tools/win.sh "$1" 2>&1 | tr -d '\r' ); }

echo "== fastboot =="
win "fastboot devices"

echo "== USB 枚举 =="
win "powershell -NoProfile -Command \"'18D1=' + (Get-CimInstance Win32_PnPEntity | Where-Object {\$_.DeviceID -like '*VID_18D1*'} | Measure-Object).Count; 'COM=' + (Get-CimInstance Win32_SerialPort | Measure-Object).Count; 'rndis=' + (Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue | Where-Object {\$_.InterfaceDescription -match 'RNDIS|Remote NDIS|CDC|NCM'} | Measure-Object).Count; (Get-CimInstance Win32_SerialPort | ForEach-Object { \$_.DeviceID + ' ' + \$_.Name }) -join '|'\""

echo "== 有问题的设备（非 OK） =="
win "powershell -NoProfile -Command \"Get-PnpDevice -PresentOnly | Where-Object {\$_.Status -ne 'OK'} | Select-Object Status,Class,FriendlyName | Format-Table -AutoSize | Out-String -Width 130\""
