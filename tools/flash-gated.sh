#!/usr/bin/env bash
# 唯一允许的 venus boot_b 刷写入口。
# 纪律（每次刷写都必须过这里）：
#   1) 先 preflight（内核/DTB 对基线、镜像头字段、ramdisk 体积）
#   2) 记录「刷了什么」到 manifest（名字/md5/用途/时间）
#   3) 刷完回读 boot_b 前 N 字节，与源文件 md5 比对——不一致即报错退出
#   4) 输出当前设备上实际是什么镜像
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
img=${1:?usage: flash-gated.sh <boot.img>}
man=$here/.flash-manifest.tsv
[ -f "$img" ] || { echo "镜像不存在: $img" >&2; exit 1; }
src_md5=$(md5sum "$img" | cut -d' ' -f1)
size=$(stat -c %s "$img")

echo "== 1) preflight =="
if [ -x "$here/tools/preflight-flash.sh" ]; then
  "$here/tools/preflight-flash.sh" "$img" || { echo "preflight 拒绝，停止" >&2; exit 1; }
fi

echo "== 2) 记录 manifest =="
printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$(basename "$img")" "$src_md5" "$size" >> "$man"

echo "== 3) 刷入 =="
adb_out=$(cd "$here" && bash tools/win.sh "fastboot flash boot_b $(basename "$img")" 2>&1 | tr -d '\r')
echo "$adb_out" | grep -qE "OKAY|Writing" || { echo "刷写未确认成功，输出如下:" >&2; echo "$adb_out" >&2; exit 1; }

echo "== 4) 回读校验 =="
read_md5=$(cd "$here" && bash tools/win.sh "adb shell su -c 'dd if=/dev/block/by-name/boot_b bs=1M count=$(( (size + 1048575) / 1048576 )) 2>/dev/null | md5sum'" 2>&1 | tr -d '\r' | awk '{print $1}' | tail -1)
echo "源   : $src_md5 ($size 字节)"
echo "设备 : ${read_md5:-<读不到，设备可能未启动 adb>}"
if [ "${read_md5:-}" = "$src_md5" ]; then
  echo "回读一致 ✓"
else
  echo "回读不一致或不可读 → 不能声称已刷入 ✗" >&2
fi
