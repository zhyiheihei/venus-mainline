#!/usr/bin/env bash
# 在手机上执行命令（走 WiFi 上的 ssh）。这是主要开发通道。
# 用法: tools/vcmd.sh "<命令>" [超时秒]
set -euo pipefail
cmd=${1:?'usage: vcmd.sh "<command>" [timeout]'}
t=${2:-60}
timeout "$t" ssh venus "$cmd"
