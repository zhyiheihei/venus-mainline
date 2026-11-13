#!/usr/bin/env bash
# 经救援系统取回完整日志（持久 journal 与 venus-debug 全量）
# 用法: fetch-logs.sh [目标目录]
set -uo pipefail
ip=${VENUS_IP:-192.168.0.150}
dest=${1:-"$HOME/venus-logs/$(date +%Y%m%d-%H%M)"}
mkdir -p "$dest"
S="ssh -p 22 -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o IdentityAgent=none -i $HOME/.ssh/id_ed25519 root@$ip"
timeout 600 $S 'tar -C /persistent -czf /tmp/vl.tgz var/log/journal venus-debug 2>/dev/null; stat -c %s /tmp/vl.tgz'
timeout 900 scp -P 22 -o BatchMode=yes -o LogLevel=ERROR -o IdentityAgent=none -i "$HOME/.ssh/id_ed25519" root@"$ip":/tmp/vl.tgz "$dest"/ >/dev/null
tar xzf "$dest/vl.tgz" -C "$dest"
rm -f "$dest/vl.tgz"
echo "logs=$dest"
ls -l --time-style=+%H:%M "$dest/venus-debug" 2>/dev/null | tail -5
