#!/usr/bin/env bash
# 在 Windows 主机上跑 adb/fastboot 命令。
# 主机/账户读 $MI11_WIN_HOST 或 ~/.config/mi11/win-host（形如 user@192.168.0.x），不进 git。
# 认证优先公钥（已装到 Windows OpenSSH 的 administrators_authorized_keys），
# 公钥不通时回退 $MI11_WIN_PASS 或 ~/.config/mi11/win-pass + sshpass。
set -euo pipefail
cfg=${XDG_CONFIG_HOME:-$HOME/.config}/mi11
host=${MI11_WIN_HOST:-$(cat "$cfg/win-host" 2>/dev/null || true)}
[ -n "$host" ] || { echo "missing windows host: set MI11_WIN_HOST or $cfg/win-host" >&2; exit 1; }
user=${host%@*}
cmd=${1:?'usage: win.sh "adb devices"'}
opts=(-o StrictHostKeyChecking=no -o LogLevel=ERROR)
remote="cd C:\\Users\\$user\\mi11 && set PATH=C:\\Users\\$user\\mi11\\platform-tools;%PATH% && $cmd"
if ssh -o BatchMode=yes "${opts[@]}" "$host" "exit" 2>/dev/null; then
  exec ssh "${opts[@]}" "$host" "$remote"
fi
pass=${MI11_WIN_PASS:-$(cat "$cfg/win-pass" 2>/dev/null || true)}
[ -n "$pass" ] || { echo "missing windows password: set MI11_WIN_PASS or $cfg/win-pass" >&2; exit 1; }
exec nix shell nixpkgs#sshpass -c sshpass -p "$pass" ssh "${opts[@]}" "$host" "$remote"
