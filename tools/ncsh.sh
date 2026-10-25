#!/usr/bin/env bash
# 通过 USB 网络上的 netcat shell 在手机上执行命令。
# 结果经 Windows 上文件中转取回(避开 PowerShell stdout 的 CLIXML/编码噪声)。
# 用法: tools/ncsh.sh "<命令>" [超时毫秒]
set -euo pipefail
cmd=${1:?'usage: ncsh.sh "<command>" [ms]'}
ms=${2:-4000}
here=$(cd "$(dirname "$0")" && pwd)

# PowerShell 里用单引号包住命令, 内部单引号转义为两个
pesc=${cmd//\'/\'\'}

ps="\$ErrorActionPreference='Stop'
\$log='C:\\Users\\<windows-user>\\mi11\\devout.txt'
try {
  \$c = New-Object System.Net.Sockets.TcpClient('10.15.0.2', 9000)
  \$s = \$c.GetStream(); \$s.ReadTimeout = 500
  \$w = New-Object IO.StreamWriter(\$s); \$w.AutoFlush = \$true
  \$w.Write('${pesc}' + [char]10 + 'exit' + [char]10)
  \$sb = New-Object System.Text.StringBuilder
  \$rd = New-Object byte[] 8192
  \$sw = [Diagnostics.Stopwatch]::StartNew()
  while (\$sw.Elapsed.TotalMilliseconds -lt $ms) {
    try { \$n = \$s.Read(\$rd,0,\$rd.Length); if (\$n -le 0) { break }; [void]\$sb.Append([Text.Encoding]::UTF8.GetString(\$rd,0,\$n)) } catch { }
  }
  \$c.Close()
  [IO.File]::WriteAllText(\$log, \$sb.ToString())
} catch { [IO.File]::WriteAllText(\$log, 'ERR ' + \$_.Exception.Message) }"

b64=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
"$here/win.sh" "powershell -NoProfile -EncodedCommand $b64" >/dev/null 2>&1 || true
"$here/_fetch.sh"
