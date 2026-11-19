#!/usr/bin/env bash
# 从 NixOS 闭包组装 boot.img（内核 / DTB / initrd / cmdline 全部取自同一闭包）
# 用法: boot-img.sh <closure> <out.img> [--dtb <dtb 文件>] [--init <init 路径>] [--from-kernel-params] [--shell]
# --init: 覆盖 cmdline 里的 init=，用于只换 initrd 而 stage-2 仍用设备上已有闭包的场景
# --from-kernel-params: cmdline 以闭包自带的 kernel-params 为底（fleet 闭包必须用这个，
#   否则会丢掉 audit=1 / lsm= / log_buf_len 等 fleet 侧要求的参数）
set -euo pipefail
closure=${1:?'usage: boot-img.sh <closure> <out.img> [--dtb <dtb>]'}
out=${2:?'usage: boot-img.sh <closure> <out.img> [--dtb <dtb>]'}
shift 2
dtb=""
init_path=""
from_kp=0
shell_req=0
while [ $# -gt 0 ]; do
  case $1 in
    --dtb) dtb=$2; shift 2;;
    --init) init_path=$2; shift 2;;
    --from-kernel-params) from_kp=1; shift;;
    --shell) shell_req=1; shift;;
    *) echo "unknown arg $1" >&2; exit 1;;
  esac
done

[ -e "$closure/init" ] || { echo "闭包不存在: $closure" >&2; exit 1; }
[ -e "$closure/kernel" ] || { echo "闭包缺 kernel: $closure" >&2; exit 1; }
[ -e "$closure/initrd" ] || { echo "闭包缺 initrd: $closure" >&2; exit 1; }

dtb=${dtb:-$closure/dtbs/qcom/sm8350-xiaomi-venus.dtb}
[ -e "$dtb" ] || { echo "DTB 不存在: $dtb" >&2; exit 1; }

init_path=${init_path:-$closure/init}
if [ "$from_kp" = 1 ] && [ -f "$closure/kernel-params" ]; then
  # fleet（nixos-config 组装的闭包）在 kernel-params 里带了一堆必须保留的参数
  # （audit=1 / lsm=landlock,yama,bpf / log_buf_len / sysctl.vm.mem_profiling 等）。
  # 这里以闭包自带的为准，只补本板必须的 console、init= 与固件路径。
  # 去掉 init=（下面重建）、重复的 console=（避免 /dev/console 落到错的设备上）、
  # 以及 vt.default_{red,grn,blu}（纯配色，单条 70+ 字符，会把 cmdline 的 512 字节主字段撑爆，
  # 撑爆后 mkbootimg 会把尾巴切到 extra_cmdline 字段，是否被 ABL 传下去不可靠）；
  # 再去掉 swapaccount=1（venus 没有 swap）与 delayacct（不需要延迟记账）。
  kp=$(sed -e 's/[[:space:]]*init=[^[:space:]]*//g' \
          -e 's/[[:space:]]*console=[^[:space:]]*//g' \
          -e 's/[[:space:]]*vt\.default_\(red\|grn\|blu\)=[^[:space:]]*//g' \
          -e 's/[[:space:]]*swapaccount=1//g' \
          -e 's/[[:space:]]*delayacct//g' \
          -e 's/[[:space:]]*ibt=off//g' \
          -e 's/[[:space:]]*split_lock_detect=[^[:space:]]*//g' \
          -e 's/[[:space:]]*kfence\.sample_interval=[^[:space:]]*//g' \
          -e 's/[[:space:]]*damon_stat\.enabled=[^[:space:]]*//g' \
          -e 's/[[:space:]]*sysctl\.vm\.mem_profiling=[^[:space:]]*//g' \
          -e 's/[[:space:]]*rcuupdate\.rcu_cpu_stall_suppress=[^[:space:]]*//g' \
          -e 's/[[:space:]]*nmi_watchdog=[^[:space:]]*//g' \
          "$closure/kernel-params" | tr '\n' ' ')
  # 去重（fleet 的 kernel-params 里 net.ifnames=0 之类会重复出现，白占 cmdline 字节）
  kp=$(printf '%s' "$kp" | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
  # regulator_ignore_unused / pd_ignore_unused / clk_ignore_unused 是 venus 的板级必需项：
  # 少了它们，WiFi 那五路 userspace-consumer regulator 会在 late init 被当成 "unused" 关掉，
  # 表现为固件早已加载成功（fw_version 正常）但 40 秒后
  # `ath11k_pci: wmi command 12291 timeout` / `failed to send WMI_SCAN_CHAN_LIST cmd`，
  # 于是 wpa_supplicant 扫不到任何信道、wlan0 永远 DOWN。2026-11-19 17:00 的 fleet 启动实测如此。
  # 板级三条现在由 boot.kernelParams 提供（nixos/venus-hardware.nix）；这里只对旧闭包兜底，
  # 已经在 $kp 里的就不重复追加。
  board=""
  for p in regulator_ignore_unused pd_ignore_unused clk_ignore_unused; do
    case " $kp " in *" $p "*) ;; *) board="$board $p";; esac
  done
  cmdline="console=ttyGS0,115200 console=tty0 $kp$board init=$init_path firmware_class.path=/run/current-system/firmware"
else
  cmdline="console=ttyGS0,115200 console=tty0 loglevel=7 consoleblank=0 root=fstab init=$init_path firmware_class.path=/run/current-system/firmware regulator_ignore_unused pd_ignore_unused clk_ignore_unused net.ifnames=0"
fi

# --shell：给 initrd 一个诊断用 root shell（nixos/venus-hardware.nix 里按 cmdline 判断）
[ "$shell_req" = 1 ] && cmdline="$cmdline venus.shell=1"
echo "cmdline=$cmdline"

work=$(mktemp -d "${TMPDIR:-/tmp}/venus-bootimg.XXXXXX")
trap 'rm -rf "$work"' EXIT

gzip -9 -n -c "$(readlink -f "$closure/kernel")" > "$work/k.gz"
cat "$work/k.gz" "$dtb" > "$work/kernel-dtb"

PYTHONPATH=$HOME/.cache/mkbootimg python3 "$HOME/.cache/mkbootimg/mkbootimg.py" \
  --header_version 2 \
  --kernel "$work/kernel-dtb" \
  --ramdisk "$(readlink -f "$closure/initrd")" \
  --dtb "$dtb" \
  --cmdline "$cmdline" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --dtb_offset 0x01f00000 --tags_offset 0x00000100 --pagesize 4096 \
  --os_version 14.0.0 --os_patch_level 2099-12 \
  -o "$out" >/dev/null

md5=$(md5sum "$out" | cut -c1-32)
echo "out=$out size=$(stat -c %s "$out") md5=$md5"
echo "closure=$closure"
echo "dtb=$dtb md5=$(md5sum "$dtb" | cut -c1-32)"
echo "init=$init_path"
