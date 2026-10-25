#!/bin/sh
findpart() {
  for u in /sys/class/block/*/uevent; do
    if grep -qx "PARTNAME=$1" "$u" 2>/dev/null; then
      basename "$(dirname "$u")"; return 0
    fi
  done
  return 1
}
B=$(findpart boot_b) || { echo NO_BOOT_B; exit 1; }
echo "boot_b -> /dev/$B"
dd if=/tmp/boot.img of="/dev/$B" bs=1M 2>&1 | tail -1
sync
echo FLASH_DONE
