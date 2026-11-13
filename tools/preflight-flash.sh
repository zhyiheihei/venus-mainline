#!/usr/bin/env bash
# 刷写前闸门：把"一次只改一个变量"和"initrd/rootfs 必须自洽"变成机器检查。
#
# 用法: tools/preflight-flash.sh <boot.img> [rootfs 解包目录]
#   基线:      BASE=~/.cache/venus-backups/known-good.md5
#   允许换内核: ALLOW_KERNEL_CHANGE=1
#   允许换 DTB: ALLOW_DTB_CHANGE=1
#   默认 rootfs 目录: ~/.cache/venus-install/root
#
# 退出码非 0 = 禁止刷写。
set -euo pipefail

img=${1:?'用法: preflight-flash.sh <boot.img> [rootfs 目录]'}
root=${2:-$HOME/.cache/venus-install/root}
BASE=${BASE:-$HOME/.cache/venus-backups/known-good.md5}
unpack=$HOME/.cache/mkbootimg/unpack_bootimg.py
fail=0
say() { printf '%s\n' "$*"; }
bad() { say "✗ $*"; fail=1; }
ok() { say "✓ $*"; }
md5() { md5sum "$1" | cut -d' ' -f1; }

[ -f "$img" ] || { say "✗ 找不到 $img"; exit 1; }
[ -f "$unpack" ] || { say "✗ 缺 unpack_bootimg.py: $unpack"; exit 1; }

W=$(mktemp -d); trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W" 2>/dev/null' EXIT
python3 "$unpack" --boot_img "$img" --out "$W/ub" >/dev/null 2>&1 || { say "✗ boot.img 解析失败"; exit 1; }

# ---- 1) 内核 + 追加 DTB：必须等于设备基线 ----
ref_kernel=$(awk '$1=="kernel"{print $2}' "$BASE" 2>/dev/null || true)
ref_dtb=$(awk '$1=="dtb"{print $2}' "$BASE" 2>/dev/null || true)
python3 - "$W/ub/kernel" "$W" <<'PY'
import gzip, io, sys, hashlib
raw=open(sys.argv[1],'rb').read()
i=raw.rfind(b'\xd0\x0d\xfe\xed')
if i < 0:
    open(sys.argv[2]+'/Image','wb').write(gzip.GzipFile(fileobj=io.BytesIO(raw)).read())
    open(sys.argv[2]+'/dtb.md5','w').write('none')
else:
    open(sys.argv[2]+'/Image','wb').write(gzip.GzipFile(fileobj=io.BytesIO(raw[:i])).read())
    open(sys.argv[2]+'/dtb.bin','wb').write(raw[i:])
    open(sys.argv[2]+'/dtb.md5','w').write(hashlib.md5(raw[i:]).hexdigest())
PY
got_kernel=$(md5 "$W/Image"); got_dtb=$(cat "$W/dtb.md5")
if [ -n "$ref_kernel" ]; then
  if [ "$got_kernel" = "$ref_kernel" ]; then ok "内核 = 基线 $got_kernel"; 
  elif [ "${ALLOW_KERNEL_CHANGE:-0}" = 1 ]; then say "… 内核与基线不同（$got_kernel ≠ $ref_kernel），ALLOW_KERNEL_CHANGE=1 已显式放行"
  else bad "内核不是设备在跑的那份（$got_kernel ≠ $ref_kernel）——禁止刷写"; fi
fi
if [ -n "$ref_dtb" ] && [ "$got_dtb" != "none" ]; then
  if [ "$got_dtb" = "$ref_dtb" ]; then ok "DTB = 基线 $got_dtb"
  elif [ "${ALLOW_DTB_CHANGE:-0}" = 1 ]; then say "… DTB 与基线不同（$got_dtb ≠ $ref_dtb），ALLOW_DTB_CHANGE=1 已显式放行"
  else bad "DTB 不是设备在跑的那份（$got_dtb ≠ $ref_dtb）——禁止刷写"; fi
fi
[ "$got_dtb" = "none" ] && bad "boot.img 的 kernel 字段里没有追加 DTB（设备是 Image.gz+DTB 布局）"

# ---- 2) initrd 自洽：init 的解释器 + preinit 引用的 store 路径都要在 ramdisk 里 ----
mkdir -p "$W/rd"; ( cd "$W/rd" && { zstd -dc "$W/ub/ramdisk" 2>/dev/null || gzip -dc "$W/ub/ramdisk"; } | cpio -idm --quiet 2>/dev/null ) || true
# init 的路径一律按 ramdisk 内部视角解析（ramdisk 就是开机时的 /）
[ -e "$W/rd/init" ] || [ -L "$W/rd/init" ] || bad "ramdisk 里没有 init"
initfile="$W/rd/init"
if [ -L "$W/rd/init" ]; then
  tgt=$(readlink "$W/rd/init"); rel=${tgt#/}
  [ -e "$W/rd/$rel" ] || bad "ramdisk 的 init 指向不存在: $tgt"
  initfile="$W/rd/$rel"
fi
if [ -f "$initfile" ]; then
  interp=$(head -c 200 "$initfile" | sed -n '1s|^#! *||p' | awk '{print $1}')
  if [ -n "$interp" ] && [ ! -e "$W/rd$interp" ]; then bad "init 的解释器不在 ramdisk 里: $interp"; else [ -n "$interp" ] && ok "init 解释器在 ramdisk 内: $interp"; fi
  for p in $(grep -oE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+' "$initfile" 2>/dev/null | sort -u); do
    [ -e "$W/rd$p" ] && continue
    case "$p" in *stage-1*|*stage-2*) continue ;; esac
    bad "init 引用的路径不在 ramdisk 里: $p"
  done
fi

# ---- 3) 与 rootfs 的配对：initrd 要用的 store 路径必须在 rootfs 里 ----
if [ -d "$root/nix/store" ]; then
  ls "$root/nix/store" | sort > "$W/rootstore"
  { grep -oE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+' "$initfile" 2>/dev/null
    ls -l "$W/rd" 2>/dev/null | grep -oE '/nix/store/[a-z0-9]{32}-[A-Za-z0-9._+-]+'
  } | sed 's|/nix/store/||' | sort -u \
    | while read -r n; do [ -e "$W/rd/nix/store/$n" ] || echo "$n"; done > "$W/need"
  miss=$(comm -23 "$W/need" "$W/rootstore" | head -20)
  if [ -n "$miss" ]; then bad "initrd 需要但 rootfs 里没有的 store 路径:"; echo "$miss" | sed 's/^/    /'; else ok "initrd 引用的 store 路径在 rootfs 里齐全（$(wc -l < "$W/need") 项）"; fi
  [ -L "$root/nix/var/nix/profiles/system" ] && ok "rootfs 已有 system profile" || bad "rootfs 缺 /nix/var/nix/profiles/system（cmdline init= 会找不到）"
else
  say "… 未找到 rootfs 目录 $root —— 跳过配对检查（配对失败是"起不来"的常见原因，请补上）"
fi

# ---- 3.5) boot 头部字段：缺 os_version/os_patch_level 会报错误码 100 ----
hdr=$(python3 "$unpack" --boot_img "$img" 2>/dev/null)
echo "$hdr" | grep -qi "os version: None" && bad "头部缺 os_version（ABL 会报错误码 100）——必须带 --os_version/--os_patch_level"
# ---- 3.6) ramdisk 体积：过大 ABL 直接拒绝（错误码 7f00）----
rsz=$(stat -c %s "$W/ub/ramdisk" 2>/dev/null || echo 0)
[ "$rsz" -gt 31457280 ] && bad "ramdisk ${rsz} 字节超过 30MB 上限（基线 29.6MB）—— ABL 装不下"
[ "$rsz" -gt 0 ] && ok "ramdisk ${rsz} 字节"

# ---- 4) 打印将要执行的刷写计划 ----
say ""
say "刷写计划（人眼确认后逐条执行）:"
say "  fastboot flash boot_b  $(basename "$img")"
say "  fastboot flash dtbo_b  dtbo-zero.img"
say "  fastboot flash userdata rootfs.simg"
say "  fastboot set_active b"
say "  fastboot reboot"
say ""
[ "$fail" = 0 ] && { say "全部检查通过，可以刷写"; exit 0; } || { say "存在未通过项 —— 禁止刷写"; exit 1; }
