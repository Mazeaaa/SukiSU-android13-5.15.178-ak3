#!/system/bin/sh
# 开机把 zram0 压缩算法切换到 lz4kd
# 逻辑：swapoff -> reset -> comp_algorithm=lz4kd -> 恢复 disksize -> mkswap -> swapon
# 任何一步失败都保持原厂状态（不改分区、不动系统文件）。
MODDIR=${0%/*}
LOG=/data/local/tmp/fuxi_zram_lz4kd.log
exec >> "$LOG" 2>&1
echo "=== $(date) post-fs-data ==="

ZRAM=/dev/block/zram0
[ -e "$ZRAM" ] || { echo "no $ZRAM, skip"; exit 0; }

if ! grep -qw lz4kd /proc/crypto; then
  echo "lz4kd 未注册（内核未内置 CONFIG_LZ4KD），保持原厂压缩算法"
  exit 0
fi

if cat /sys/block/zram0/comp_algorithm 2>/dev/null | grep -q '\[lz4kd\]'; then
  echo "已经是 lz4kd，跳过"
  exit 0
fi

# 记录原 disksize（init 已配置时通常非 0）
size=$(cat /sys/block/zram0/disksize 2>/dev/null)
echo "old disksize=$size"

swapoff "$ZRAM" 2>/dev/null
swapoff -a 2>/dev/null
echo 1 > /sys/block/zram0/reset 2>/dev/null

if ! echo lz4kd > /sys/block/zram0/comp_algorithm 2>/dev/null; then
  echo "设置 comp_algorithm 失败（设备仍在使用？），保持原厂"
  exit 1
fi

[ -n "$size" ] && [ "$size" != "0" ] || size=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) * 1024 / 2 ))
echo "$size" > /sys/block/zram0/disksize || { echo "set disksize 失败"; exit 1; }

mkswap "$ZRAM" >/dev/null 2>&1
swapon "$ZRAM" >/dev/null 2>&1
echo "切换完成: $(cat /sys/block/zram0/comp_algorithm) disksize=$size"
