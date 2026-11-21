#!/usr/bin/env bash
# 经 WiFi SSH 部署到 venus（M3 之后的唯一部署路径，不需要 fastboot）。
#
#   tools/deploy.sh <closure> [--boot-img <img>] [--no-reboot]
#   tools/deploy.sh <closure> --build-boot-img        # 用 tools/boot-img.sh 现组 boot.img
#
# 做四件事：推闭包 → （可选）写 boot_b 与 boot_a 并逐个读回校验 → 切 system profile + 建 GC 根 → 重启
#
# 端口：VENUS_PORT（standalone 版 sshd 在 22，fleet 版在 2222）。
#
# 为什么必须切 profile 并建 GC 根：`nix copy` 不创建 root，nix.gc 会删掉不可达路径，
# 推上去的闭包会被清空（表现为下次启动 bash 不存在、getty 无限登录提示）。
#
# boot_b 用 dd 直写：venus 的 ABL 接受 dd 写入的 boot_b（deadman 回滚用的就是这条路），
# 但**必须**用 tools/boot-img.sh 生成镜像 —— 手拼 cmdline 漏 `root=fstab` 会得到
# "无网无串口零日志"的黑箱启动失败。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ip=${VENUS_IP:-192.168.0.68}
user=${VENUS_USER:-root}
port=${VENUS_PORT:-22}
sshopt=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o IdentityAgent=none -p "$port")
scpopt=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no -o LogLevel=ERROR -P "$port")

closure=${1:?'usage: deploy.sh <closure> [--boot-img <img>|--build-boot-img] [--no-reboot]'}
shift
img=""; reboot=1
while [ $# -gt 0 ]; do
  case $1 in
    --boot-img) img=$2; shift 2;;
    --build-boot-img) img=$(mktemp /tmp/venus-boot.XXXXXX.img); "$here/boot-img.sh" "$closure" "$img" >/dev/null; shift;;
    --no-reboot) reboot=0; shift;;
    *) echo "unknown arg $1" >&2; exit 1;;
  esac
done

[ -e "$closure/init" ] || { echo "闭包不存在: $closure" >&2; exit 1; }

echo "== 推闭包 $closure"
nix copy --no-check-sigs --to "ssh://$user@$ip:$port" "$closure"

# 硬性前置检查：boot.img 里写死的 init= 必须真的在设备的 store 里存在。
# 2026-11-19 踩过：先 nix copy 旧闭包 → 重建得到新闭包 → 直接 flash 新 boot.img，
# 结果 initrd 找不到 init= 指向的闭包，进 emergency（有 gadget 但无网络，零日志）。
if [ -n "$img" ]; then
  init_path=$(python3 - "$img" <<'PYEOF' 2>/dev/null || true
import sys,re
d=open(sys.argv[1],'rb').read()
cm=d[0x40:0x40+512].split(b'\0')[0].decode()
m=re.search(r'init=(\S+)', cm)
print(m.group(1) if m else '')
PYEOF
)
  if [ -z "$init_path" ]; then echo "✗ 无法从 boot.img 解析 init=（cmdline 缺 init=？）" >&2; exit 1; fi
  if ! ssh "${sshopt[@]}" "$user@$ip" "test -e '$init_path'"; then
    echo "✗ boot.img 的 init= 在设备上不存在：$init_path" >&2
    echo "  先把闭包 nix copy 上去，或改用正确的 boot.img（否则 initrd 进 emergency，无网无日志）" >&2
    exit 1
  fi
  echo "   init= 在设备上存在: $init_path"
fi

if [ -n "$img" ]; then
  [ -f "$img" ] || { echo "boot.img 不存在: $img" >&2; exit 1; }
  size=$(stat -c %s "$img"); md5=$(md5sum "$img" | cut -c1-32)
  echo "== 写 boot_b + boot_a: $img ($size 字节, md5 $md5)"
  scp "${scpopt[@]}" "$img" "$user@$ip:/nix/persistent/boot-deploy.img" >/dev/null
  # 两个槽写同一份（AGENTS 第 16 节）：b 槽起不来时 ABL 回落 a 槽，a 槽必须是新 initrd。
  for slot in boot_b boot_a; do
    remote=$(ssh "${sshopt[@]}" "$user@$ip" "
      set -e
      md5sum /nix/persistent/boot-deploy.img | cut -c1-32
      dd if=/nix/persistent/boot-deploy.img of=/dev/disk/by-partlabel/$slot bs=1M conv=fsync 2>/dev/null
      sync
      head -c $size /dev/disk/by-partlabel/$slot | md5sum | cut -c1-32
    " | tr -d '\r' | tail -1)
    [ "$remote" = "$md5" ] || { echo "✗ $slot 读回 md5 不符（写前 $md5，读回 $remote），停止" >&2; exit 1; }
    echo "   $slot 读回校验通过: $remote"
    sleep 3
  done
  ssh "${sshopt[@]}" "$user@$ip" 'rm -f /nix/persistent/boot-deploy.img'
fi

echo "== 切 profile + GC 根"
ssh "${sshopt[@]}" "$user@$ip" "set -e
  nix-env -p /nix/var/nix/profiles/system --set '$closure'
  nix-store --add-root /nix/persistent/system-gcroot --indirect -r '$closure' >/dev/null
  readlink -f /nix/var/nix/profiles/system"

if [ "$reboot" = 1 ]; then
  echo "== 重启"
  ssh "${sshopt[@]}" "$user@$ip" 'systemctl reboot' || true
  echo "   已发出重启；约 40~60 秒后可再连 $ip"
fi
