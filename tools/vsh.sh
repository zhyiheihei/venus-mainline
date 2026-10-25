#!/usr/bin/env bash
# 打开一个交互式 shell（走 WiFi 上的 ssh）。
set -euo pipefail
exec ssh -t venus "${@:-sh -i}"
