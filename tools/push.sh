#!/usr/bin/env bash
# 通过 NCM 网络把本地文件推到手机。
# 方向: 手机侧 busybox nc 监听, Windows 侧主动连过去发送(避免在 Windows 上起后台服务)。
# 用法: tools/push.sh <本地文件> <手机目标路径> [端口]
set -euo pipefail
src=${1:?'usage: push.sh <local> <remote> [port]'}
dst=${2:?'usage: push.sh <local> <remote> [port]'}
port=${3:-9000}
here=$(cd "$(dirname "$0")" && pwd)
base=$(basename "$src")
size=$(stat -c%s "$src")
md5=$(md5sum "$src" | cut -d' ' -f1)

# 1) 文件先落到 Windows(它才有到手机 10.15.0.2 的路由)
nix shell nixpkgs#sshpass -c sshpass -p "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/mi11/win-pass")" \
  scp -o StrictHostKeyChecking=no -o LogLevel=ERROR "$src" "<windows-user>@<LAN_WINDOWS_IP>:C:/Users/<windows-user>/mi11/$base"

# 2) 手机侧先监听
"$here/serial.sh" "rm -f $dst; nc -l -p $port > $dst </dev/null &" >/dev/null 2>&1 || true
sleep 1

# 3) Windows 侧把文件发过去
ps=$(cat <<PS1
\$ErrorActionPreference='Stop'
try {
  \$c = New-Object System.Net.Sockets.TcpClient("10.15.0.2", $port)
  \$s = \$c.GetStream(); \$fs = [IO.File]::OpenRead("C:\Users\<windows-user>\mi11\\$base")
  \$fs.CopyTo(\$s); \$s.Flush(); \$c.Close(); \$fs.Close()
  Write-Output "SENT_OK"
} catch { Write-Output ("ERR " + \$_.Exception.Message) }
PS1
)
b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
"$here/win.sh" "powershell -NoProfile -EncodedCommand $b64" 2>&1 | tr -d '\r' | grep -E 'SENT_OK|ERR' | head -2

# 4) 校验
sleep 1
"$here/serial.sh" "md5sum $dst; wc -c < $dst" 2>&1 | grep -vE '^#|^<Objs' | tail -4
echo "期望: $size 字节  md5=$md5"
