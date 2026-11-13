#!/usr/bin/env bash
# 经 Windows 的 COM 口向设备发命令并读回（设备侧 serial-getty@ttyGS0）
# 用法: serial.sh "<命令>" [秒数]   |  serial.sh --read [秒数]
# 命令写在文件里传到 Windows 再发，避免经 cmd.exe 时被 | ; 等字符破坏
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
port=${MI11_COM:-COM3}
baud=${MI11_BAUD:-115200}
winuser=${MI11_WIN_USER:-molis}
if [ "${1:-}" = "--read" ]; then sec=${2:-5}; payload="";
else sec=${2:-8}; payload=${1:?'usage: serial.sh "<命令>" [秒] | serial.sh --read [秒]'}; fi

tmp=$(mktemp)
if [ -n "$payload" ]; then printf '%s\n' "$payload" > "$tmp";
  scp -o StrictHostKeyChecking=no -o LogLevel=ERROR "$tmp" "$winuser@192.168.0.143:/Users/$winuser/mi11/serial-cmd.txt" >/dev/null || { rm -f "$tmp"; echo "传命令文件失败" >&2; exit 1; }
fi
rm -f "$tmp"

( cd "$here/.." && timeout $((sec + 40)) env -u SSH_AUTH_SOCK bash tools/win.sh \
  "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\$winuser\\mi11\\ser.ps1 -file C:\\Users\\$winuser\\mi11\\serial-cmd.txt -sec $sec -port $port -baud $baud" 2>&1 | tr -d '\r' )
