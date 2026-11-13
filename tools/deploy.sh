#!/usr/bin/env bash
# 经救援/正式系统的 SSH 部署：推闭包 -> 切 profile -> 可选写 boot_b -> 重启
# 用法: deploy.sh <closure> [--boot-img <img>] [--no-reboot]
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root="$here/.."
ip=${VENUS_IP:-192.168.0.150}
closure=${1:?'usage: deploy.sh <closure> [--boot-img <img>] [--no-reboot]'}
shift
img=""; reboot=1
while [ $# -gt 0 ]; do
  case $1 in
    --boot-img) img=$2; shift 2;;
    --no-reboot) reboot=0; shift;;
    *) echo "unknown arg $1" >&2; exit 1;;
  esac
done

ssh_port=""
for p in 22 2222; do
  if timeout 8 ssh -p $p -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      -o IdentityAgent=none -i "$HOME/.ssh/id_ed25519" root@"$ip" true 2>/dev/null; then
    ssh_port=$p; break
  fi
done
[ -n "$ssh_port" ] || { echo "设备不可达（22/2222 都登不进去）" >&2; exit 1; }
echo "== 设备可登录: port $ssh_port =="

S="ssh -p $ssh_port -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=no -o IdentityAgent=none -i $HOME/.ssh/id_ed25519 root@$ip"
export NIX_SSHOPTS="-p $ssh_port -o BatchMode=yes -o StrictHostKeyChecking=no -o IdentityAgent=none -i $HOME/.ssh/id_ed25519"

echo "== 推闭包 =="
nix copy --no-check-sigs --to "ssh://root@$ip" "$closure" 2>&1 | tail -2

if [ -n "$img" ]; then
  echo "== 传 boot.img 并写 boot_b =="
  base=$(basename "$img")
  scp -P $ssh_port -o BatchMode=yes -o LogLevel=ERROR -o IdentityAgent=none -i "$HOME/.ssh/id_ed25519" "$img" root@"$ip":/tmp/ >/dev/null
  $S "nix-env --profile /nix/var/nix/profiles/system --set '$closure' 2>&1 | tail -1
      readlink -f /nix/var/nix/profiles/system | sed 's|.*-nixos-system-||'
      S=\$(stat -c %s /tmp/$base)
      dd if=/tmp/$base of=/dev/disk/by-partlabel/boot_b bs=1M conv=fsync 2>&1 | tail -1
      sync
      echo readback=\$(head -c \$S /dev/disk/by-partlabel/boot_b | md5sum | cut -c1-32)"
else
  $S "nix-env --profile /nix/var/nix/profiles/system --set '$closure' 2>&1 | tail -1
      readlink -f /nix/var/nix/profiles/system | sed 's|.*-nixos-system-||'"
fi

if [ "$reboot" = 1 ]; then
  echo "== 重启 =="
  $S 'sync; (reboot >/dev/null 2>&1 &); echo rebooting'
fi
