#!/usr/bin/env bash
# 把本地 shell 脚本推到手机并在手机上执行, 回传它的输出。
# 用法: tools/device-run.sh <本地脚本> [超时毫秒]
# 说明: 命令里不要用 $() 或 $var 直接走 ncsh(会被 PowerShell 展开), 统一用这个包装。
set -euo pipefail
src=${1:?'usage: device-run.sh <local-script> [ms]'}
ms=${2:-8000}
here=$(cd "$(dirname "$0")" && pwd)
name=$(basename "$src")
nix shell nixpkgs#sshpass -c sshpass -p "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/mi11/win-pass")" \
  scp -o StrictHostKeyChecking=no -o LogLevel=ERROR "$src" "<windows-user>@<LAN_WINDOWS_IP>:C:/Users/<windows-user>/mi11/$name" >/dev/null
ps=$(cat <<PS1
\$ErrorActionPreference='Stop'
function Drain(\$p,\$ms){ \$sb=New-Object System.Text.StringBuilder; \$sw=[Diagnostics.Stopwatch]::StartNew(); while(\$sw.Elapsed.TotalMilliseconds -lt \$ms){ try{\$s=\$p.ReadExisting(); if(\$s){[void]\$sb.Append(\$s)}}catch{}; Start-Sleep -Milliseconds 80 }; return \$sb.ToString() }
try {
  \$c = New-Object System.Net.Sockets.TcpClient("10.15.0.2", 9000)
  \$s = \$c.GetStream(); \$s.ReadTimeout = 500
  \$w = New-Object IO.StreamWriter(\$s); \$w.AutoFlush = \$true
  \$w.Write("nc 10.15.0.1 9300 > /tmp/$name; echo PUSHED; exit" + "\`n")
  [void](Drain \$s 1500)
  \$l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse("10.15.0.1"), 9300)
  \$l.Start(); \$cl = \$l.AcceptTcpClient(); \$cs = \$cl.GetStream()
  \$fs = [IO.File]::OpenRead("C:\Users\<windows-user>\mi11\\\$name"); \$fs.CopyTo(\$cs); \$cs.Flush()
  \$cl.Close(); \$fs.Close(); \$l.Stop()
  \$c2 = New-Object System.Net.Sockets.TcpClient("10.15.0.2", 9000)
  \$s2 = \$c2.GetStream(); \$s2.ReadTimeout = 500
  \$w2 = New-Object IO.StreamWriter(\$s2); \$w2.AutoFlush = \$true
  \$w2.Write("sh /tmp/$name > /tmp/$name.out 2>&1; echo RAN; exit" + "\`n")
  [void](Drain \$s2 1200)
  \$w2.Write("cat /tmp/$name.out; echo OUT_DONE; exit" + "\`n")
  \$out = Drain \$s2 $ms
  \$c2.Close()
  [IO.File]::WriteAllText("C:\\Users\\<windows-user>\\mi11\\devout.txt", \$out)
  Write-Output ("WROTE " + \$out.Length)
} catch { Write-Output ("ERR " + \$_.Exception.Message) }
PS1
)
b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
"$here/win.sh" "powershell -NoProfile -EncodedCommand $b64" >/dev/null 2>&1 || true
nix shell nixpkgs#sshpass -c sshpass -p "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/mi11/win-pass")" \
  scp -o StrictHostKeyChecking=no -o LogLevel=ERROR "<windows-user>@<LAN_WINDOWS_IP>:C:/Users/<windows-user>/mi11/devout.txt" /tmp/devout.txt >/dev/null 2>&1
cat /tmp/devout.txt 2>/dev/null
