#!/usr/bin/env bash
# 收集自建内核产物（Image + 全部模块 + modinfo）到 nixos/kernel/，
# 供 nixos/kmods-package.nix 打包成标准 /lib/modules/7.2.6 布局。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
build=${1:-$HOME/.cache/venus-kernel/linux-build}
out=$root/nixos/kernel

rm -rf "$out"; mkdir -p "$out/mod"
install -m644 "$build/arch/arm64/boot/Image" "$out/Image"
for f in modules.order modules.builtin modules.builtin.modinfo; do
  [ -f "$build/$f" ] && install -m644 "$build/$f" "$out/$f"
done
# 只收 modules.order 里列出的模块：内核树里可能残留"已改为内建"的旧 .ko，
# 它们会让 depmod/modprobe 命中错误文件（报 invalid module format / 符号重复）。
while read -r rel; do
  [ -z "$rel" ] && continue
  ko=${rel%.o}.ko
  [ -f "$build/$ko" ] || continue
  install -Dm644 "$build/$ko" "$out/mod/$ko"
done < "$build/modules.order"
echo "模块数量: $(find "$out/mod" -name '*.ko' | wc -l)  体积: $(du -sh "$out" | cut -f1)"
