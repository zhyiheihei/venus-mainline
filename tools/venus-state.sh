#!/usr/bin/env bash
# venus 当前状态与身份。任何设备操作前先跑这个。串口只查 Windows 端，设备从不连本机。
set -uo pipefail
IP=${VENUS_IP:-192.168.0.150}
KEY=$HOME/.ssh/id_ed25519
HERE=$(cd "$(dirname "$0")/.." && pwd)
TRY="ssh -o BatchMode=yes -o ConnectTimeout=4 -o StrictHostKeyChecking=no -o IdentityAgent=none -i $KEY"

probe() {
  timeout 10 $TRY -p "$1" "root@$IP" \
    'readlink -f /run/current-system | sed "s|.*-nixos-system-||"; uname -r; systemctl is-active graphical.target 2>/dev/null' 2>/dev/null | tr '\n' ' '
}

serial() {
  local out
  out=$(cd "$HERE" && timeout 60 env -u SSH_AUTH_SOCK bash tools/win.sh \
    "powershell -NoProfile -Command \"(Get-CimInstance Win32_SerialPort | Select-Object -ExpandProperty DeviceID) -join ','\"" 2>/dev/null | tr -d '\r' | tr -d '\n')
  out=${out//[[:space:]]/}
  if [ -n "$out" ]; then echo "win_serial=$out"; else echo "win_serial=none"; fi
}

state=none; detail=""
for _ in 1 2 3; do
  if d=$(probe 2222); [ -n "$d" ]; then state=fleet; detail=$d; break; fi
  if d=$(probe 22); [ -n "$d" ]; then state=rescue; detail=$d; break; fi
  if timeout 8 fastboot devices 2>/dev/null | grep -q fastboot; then state=fastboot; break; fi
  sleep 5
done
[ "$state" = none ] && { timeout 3 ping -c1 -W1 "$IP" >/dev/null 2>&1 && state=booting; }

echo "state=$state${detail:+ | $detail}"
serial
case $state in
  fleet)  echo "fleet 正式系统（ssh 2222）。刷 boot_b：scp 后 dd，不需要 fb" ;;
  rescue) echo "救援系统（ssh 22，自带桌面的完整 NixOS）。刷 boot_b：scp 后 dd，不需要 fb" ;;
  fastboot) echo "已在 fastboot，可直接刷 boot_b" ;;
  booting) echo "有网络但 SSH 未起：等 2 分钟重跑；仍不通按下面规则处理" ;;
  none) echo "不可达" ;;
esac
case $state in
  none|booting)
    if timeout 60 env -u SSH_AUTH_SOCK bash "$HERE/tools/win.sh" "powershell -NoProfile -Command \"if ((Get-CimInstance Win32_SerialPort | Measure-Object).Count -gt 0) {'yes'} else {'no'}\"" 2>/dev/null | tr -d '\r\n' | grep -q yes; then
      echo "有串口：读串口取日志，不必进 fb"
    else
      echo "无串口：叫用户进 fb"
    fi
    ;;
esac
