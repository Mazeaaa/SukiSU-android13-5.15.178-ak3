#!/system/bin/sh
# 开机后写一份状态到日志，便于确认是否真的生效
LOG=/data/local/tmp/fuxi_zram_lz4kd.log
{
  echo "=== $(date) service（状态确认） ==="
  echo "comp_algorithm: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
  echo "disksize: $(cat /sys/block/zram0/disksize 2>/dev/null)"
  echo "mm_stat: $(cat /sys/block/zram0/mm_stat 2>/dev/null)"
  grep -w lz4kd /proc/crypto 2>/dev/null | head -3
} >> "$LOG" 2>&1
