#!/usr/bin/env bash
# 在 Windows 主机 (<windows-user>@<LAN_WINDOWS_IP>) 上跑 adb/fastboot 命令。
# 密码从 $MI11_WIN_PASS 或 ~/.config/mi11/win-pass 读取, 不进 git。
set -euo pipefail
pass=${MI11_WIN_PASS:-$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/mi11/win-pass" 2>/dev/null || true)}
[ -n "$pass" ] || { echo "missing windows password: set MI11_WIN_PASS or ~/.config/mi11/win-pass" >&2; exit 1; }
cmd=${1:?'usage: win.sh "adb devices"'}
exec nix shell nixpkgs#sshpass -c sshpass -p "$pass" ssh \
  -o StrictHostKeyChecking=no -o LogLevel=ERROR <windows-user>@<LAN_WINDOWS_IP> \
  "cd C:\\Users\\<windows-user>\\mi11 && set PATH=C:\\Users\\<windows-user>\\mi11\\platform-tools;%PATH% && $cmd"
