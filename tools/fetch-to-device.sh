#!/usr/bin/env bash
# 把本地文件推到手机(设备侧用 nc 主动连 Windows 的临时监听), 用于 nc 命令外壳不可用时。
# 用法: tools/fetch-to-device.sh <本地文件> <手机路径> [端口=9300]
set -euo pipefail
src=${1:?'usage: fetch-to-device.sh <local> <remote>'}
dst=${2:?'usage: fetch-to-device.sh <local> <remote>'}
port=${3:-9300}
here=$(cd "$(dirname "$0")" && pwd)
base=$(basename "$src")
size=$(stat -c%s "$src")
md5=$(md5sum "$src" | cut -d' ' -f1)
pass=$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/mi11/win-pass")

# 1) 传到 Windows
nix shell nixpkgs#sshpass -c sshpass -p "$pass" \
  scp -o StrictHostKeyChecking=no -o LogLevel=ERROR "$src" "<windows-user>@<LAN_WINDOWS_IP>:C:/Users/<windows-user>/mi11/$base"

# 2) 后台起一次性监听(同步阻塞在它自己的 SSH 会话里)
ps="\$ErrorActionPreference='Stop'
try {
  \$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('10.15.0.1'), $port)
  \$l.Start()
  \$cl = \$l.AcceptTcpClient(); \$cs = \$cl.GetStream()
  \$fs = [IO.File]::OpenRead('C:\\Users\\<windows-user>\\mi11\\$base')
  \$fs.CopyTo(\$cs); \$cs.Flush(); \$cl.Close(); \$fs.Close(); \$l.Stop()
  [IO.File]::WriteAllText('C:\\Users\\<windows-user>\\mi11\\serve.log','SENT')
} catch { [IO.File]::WriteAllText('C:\\Users\\<windows-user>\\mi11\\serve.log','ERR ' + \$_.Exception.Message) }"
b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
("$here/win.sh" "powershell -NoProfile -EncodedCommand $b64" >/dev/null 2>&1 &) 
sleep 3

# 3) 设备侧主动取
"$here/serial.sh" "rm -f $dst; nc 10.15.0.1 $port > $dst; md5sum $dst" 2>&1 | sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' | tail -3
echo "期望: $size 字节  md5=$md5"
