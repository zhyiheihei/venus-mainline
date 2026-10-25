#!/usr/bin/env bash
# 从本机的 ROM / 分区镜像里提取 venus 需要的厂商固件到 nixos/firmware/
# （固件不进 git；换机器时重跑这个脚本即可）
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../nixos/firmware"
work=${WORK:-$HOME/mi11-work}
mkdir -p "$out" "$out/ath11k/WCN6855/hw1.1" "$out/qca"

# 1) ath11k（WiFi）：modem 分区 image/ 下的 amss/m3/regdb + bdwlan ELF 当 board.bin
if [ -d "$work/mdm/image" ]; then
  cp "$work/mdm/image/amss.bin" "$work/mdm/image/m3.bin" "$work/mdm/image/regdb.bin" \
     "$out/ath11k/WCN6855/hw1.1/" 2>/dev/null || true
  cp "$work/mdm/image/bdwlan.e01" "$out/ath11k/WCN6855/hw1.1/board.bin" 2>/dev/null || true
else
  echo "缺少 $work/mdm/image（modem 分区提取）" >&2
fi

# 2) GPU（Adreno 660）：vendor 分区 firmware/ 下
for f in a660_gmu.bin a660_sqe.fw a660_zap.b00 a660_zap.b01 a660_zap.b02 a660_zap.elf a660_zap.mdt; do
  [ -f "$work/vfw/firmware/$f" ] && cp "$work/vfw/firmware/$f" "$out/"
done

# 3) 蓝牙（WCN6851）：bluetooth 分区（FAT）image/ 下
# 芯片 ROM 版本可能是 0x10 或 0x21：把两套都放上，并同时提供 wcnhpnv*/hpnv* 两种命名
if [ -d "$work/btfw" ]; then
  cp "$work"/btfw/hpbtfw*.tlv "$out/qca/" 2>/dev/null || true
  for f in "$work"/btfw/hpnv*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    cp "$f" "$out/qca/$b"
    cp "$f" "$out/qca/wcn$b"
  done
fi

echo "固件已就绪: $out"
find "$out" -type f | sed "s|$out/||" | sort
