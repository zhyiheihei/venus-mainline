#!/usr/bin/env bash
# 把仓库里的 NixOS 配置推到设备上并 switch（走 WiFi ssh）。
# 用法: tools/deploy-nixos.sh [boot|switch]
set -euo pipefail
action=${1:-switch}
here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."

# 固件目录（configuration.nix 里用 ./firmware 引用）
"$here/vpush.sh" "$root/nixos/firmware" /etc/nixos/ >/dev/null 2>&1 || true
"$here/vpush.sh" "$root/nixos/configuration.nix" /etc/nixos/configuration.nix >/dev/null 2>&1 || true

echo "已在设备上执行 nixos-rebuild $action ..."
ssh venus "date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')' >/dev/null 2>&1 || true; \
  setsid nohup nixos-rebuild $action > /tmp/nixos-rebuild.log 2>&1 </dev/null & sleep 1; echo started"
echo "进度: ssh venus 'tail -f /tmp/nixos-rebuild.log'"
