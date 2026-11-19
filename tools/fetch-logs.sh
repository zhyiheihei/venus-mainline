#!/usr/bin/env bash
# 取回 venus 的完整日志（M3：直接 rsync 设备 /nix/persistent）。
# 用法: fetch-logs.sh [目标目录]
#   VENUS_IP 默认 192.168.0.68
# 内容：/nix/persistent 全量（含 venus-debug/journal-b.log、venus-diag.log、venus-dmesg.log、
#       venus-initrd-boot.log、deadman 计数与日志、boot-milestone.img）。
set -uo pipefail
ip=${VENUS_IP:-192.168.0.68}
dest=${1:-"$HOME/venus-logs/$(date +%Y%m%d-%H%M)"}
mkdir -p "$dest"
sshopt="ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o IdentityAgent=none"

echo "== journalctl -b 落盘（设备侧）"
timeout 180 $sshopt root@"$ip" 'mkdir -p /nix/persistent/venus-debug; journalctl -b --no-pager > /nix/persistent/venus-debug/journal-b.log 2>&1; systemctl --failed --no-pager > /nix/persistent/venus-debug/failed.log 2>&1; echo ok'

echo "== rsync /nix/persistent -> $dest/persistent"
timeout 1800 rsync -az -e "${sshopt}" root@"$ip":/nix/persistent/ "$dest/persistent/" || {
  echo "rsync 失败，退回 tar 方式" >&2
  timeout 900 $sshopt root@"$ip" 'tar -C /nix/persistent -czf /tmp/vl.tgz . 2>/dev/null; stat -c %s /tmp/vl.tgz'
  timeout 1200 scp -o BatchMode=yes -o LogLevel=ERROR -o IdentityAgent=none root@"$ip":/tmp/vl.tgz "$dest"/ >/dev/null && tar xzf "$dest/vl.tgz" -C "$dest" && rm -f "$dest/vl.tgz"
  $sshopt root@"$ip" 'rm -f /tmp/vl.tgz' || true
}
echo "已取回 -> $dest"
ls -l "$dest/persistent" 2>/dev/null | head -10
