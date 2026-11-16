#!/usr/bin/env bash
# 把 26.11 闭包部署到设备（先在 25.05 用户态下跑，全程保留可回落的 boot.img）。
#
#   tools/deploy-2611.sh <closure>
#
# 为什么不用 `nix copy` 直接切换：
#   1. `nix copy` 不会创建 GC root。NixOS 的 `nix.gc.automatic` 每周执行
#      `nix-collect-garbage -d`，会删掉所有不可达路径（与年龄无关），于是刚推上去的
#      26.11 闭包会被删空，表现为下次启动 `Cannot execute /run/current-system/sw/bin/bash`，
#      getty 无限打印登录提示、无法登录（2026-11-16 实测踩到）。
#      所以必须 copy 之后立刻 `nix-env -p …/system --set <closure>` 建根，再 switch。
#   2. 26.11 的内核/initrd 与 25.05 不同，冷启动未验证前不能直接替换唯一 boot 槽。
set -euo pipefail
closure=${1:?'usage: deploy-2611.sh <closure>'}
dev=${VENUS_HOST:-root@192.168.0.150}
ssh_opts=(-o BatchMode=yes -o StrictHostKeyChecking=no)

say() { printf '\n== %s ==\n' "$*"; }

say "1/5 确认设备在 25.05 用户态且串口/WiFi 在线"
ssh "${ssh_opts[@]}" "$dev" 'readlink -f /run/current-system; ip -4 -br addr show wlan0; cat /sys/class/udc/a600000.usb/state' \
  || { echo "设备不可达：先 fastboot flash boot_b boot-1025c.img 恢复" >&2; exit 1; }

say "2/5 推送 26.11 闭包（含全部依赖）"
nix copy --no-check-sigs --to "ssh-ng://$dev" "$closure"

say "3/5 建立 GC 根并校验闭包完整性"
ssh "${ssh_opts[@]}" "$dev" "nix-env -p /nix/var/nix/profiles/system --set '$closure' &&
  bad=0; while read -r p; do nix-store --check-validity \"\$p\" 2>/dev/null || { echo \"MISSING \$p\"; bad=1; }; done < <(nix-store -qR '$closure');
  [ \$bad = 0 ] && echo ALL_PATHS_VALID"

say "4/5 switch（只换用户态，不动 boot 槽）"
ssh "${ssh_opts[@]}" "$dev" "'$closure'/bin/switch-to-configuration switch"

say "5/5 验证 WiFi / 串口 / 失败单元"
ssh "${ssh_opts[@]}" "$dev" 'readlink -f /run/current-system; ip -4 -br addr show wlan0; iw dev wlan0 link | head -3; cat /sys/class/udc/a600000.usb/state; systemctl --failed --no-pager | head -3'

cat <<'EOM'

完成：用户态已切到 26.11，boot 槽仍是 25.05 的 boot.img（重启会回到 25.05）。
要做冷启动验证，另跑：
  tools/boot-img.sh <相同 closure> /tmp/boot-2611.img
然后在设备上 dd 到 boot_b（先确认 /persistent 或 Windows 上留着 boot-1025c.img 供回落）。
EOM
