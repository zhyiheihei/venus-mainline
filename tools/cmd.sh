#!/usr/bin/env bash
# 通过 9000(收命令) / 9001(发输出) 两个一次性连接在手机上执行命令。
# 用法: tools/cmd.sh "<命令或脚本路径>" [读取毫秒]
set -euo pipefail
cmd=${1:?'usage: cmd.sh "<command>" [ms]'}
ms=${2:-4000}
here=$(cd "$(dirname "$0")" && pwd)
pesc=${cmd//\'/\'\'}

ps="\$ErrorActionPreference='Stop'
\$log='C:\\Users\\<windows-user>\\mi11\\devout.txt'
try {
  \$c1 = New-Object System.Net.Sockets.TcpClient('10.15.0.2', 9000)
  \$s1 = \$c1.GetStream(); \$w1 = New-Object IO.StreamWriter(\$s1); \$w1.AutoFlush = \$true
  \$w1.Write('${pesc}' + [char]10); Start-Sleep -Milliseconds 250; \$c1.Close()
  Start-Sleep -Milliseconds 1800
  \$c2 = New-Object System.Net.Sockets.TcpClient('10.15.0.2', 9001)
  \$s2 = \$c2.GetStream(); \$s2.ReadTimeout = 600
  \$sb = New-Object System.Text.StringBuilder; \$rd = New-Object byte[] 8192
  \$sw = [Diagnostics.Stopwatch]::StartNew()
  while (\$sw.Elapsed.TotalMilliseconds -lt $ms) {
    try { \$n = \$s2.Read(\$rd,0,\$rd.Length); if (\$n -le 0) { break }; [void]\$sb.Append([Text.Encoding]::UTF8.GetString(\$rd,0,\$n)) } catch { }
  }
  \$c2.Close()
  [IO.File]::WriteAllText(\$log, \$sb.ToString())
} catch { [IO.File]::WriteAllText(\$log,'ERR ' + \$_.Exception.Message) }"

b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
"$here/win.sh" "powershell -NoProfile -EncodedCommand $b64" >/dev/null 2>&1 || true
"$here/_fetch.sh"
