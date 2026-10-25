#!/usr/bin/env bash
# 从 Windows 主机取回 devout.txt(各工具把结果写到这里), 避免 PowerShell stdout 的 CLIXML 噪声
set -euo pipefail
nix shell nixpkgs#sshpass -c sshpass -p "$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/mi11/win-pass")" \
  scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \
  "<windows-user>@<LAN_WINDOWS_IP>:C:/Users/<windows-user>/mi11/devout.txt" /tmp/devout.txt >/dev/null 2>&1 || true
cat /tmp/devout.txt 2>/dev/null
