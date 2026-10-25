#!/usr/bin/env bash
# 在 Windows 主机的 COM3 上执行一条命令（手机跑 NixOS，串口是 ttyGS0 上的 shell）。
# 用法: tools/wserial.sh "<命令>" [等待秒]
set -euo pipefail
cmd=${1:?'usage: wserial.sh "<cmd>" [sec]'}
sec=${2:-12}
here=$(cd "$(dirname "$0")" && pwd)
pesc=${cmd//\'/\'\'}
ps="\$log='C:\\Users\\<windows-user>\\mi11\\devout.txt'
\$sb = New-Object System.Text.StringBuilder
\$p = New-Object System.IO.Ports.SerialPort('COM3',115200,'None',8,[System.IO.Ports.StopBits]::One)
\$p.ReadTimeout=800; \$p.Open(); Start-Sleep -Milliseconds 300
[void]\$p.ReadExisting()
\$p.Write('${pesc}' + \"\`r\")
\$sw=[Diagnostics.Stopwatch]::StartNew()
while (\$sw.Elapsed.TotalSeconds -lt $sec) {
  try { \$s=\$p.ReadExisting(); if (\$s) { [void]\$sb.Append(\$s) } } catch {}
  Start-Sleep -Milliseconds 120
}
\$p.Close()
[IO.File]::WriteAllText(\$log, \$sb.ToString())"
b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
"$here/win.sh" "powershell -NoProfile -EncodedCommand $b64" >/dev/null 2>&1 || true
"$here/_fetch.sh" | sed -e 's/\r$//' -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g'
