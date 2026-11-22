#!/system/bin/sh
# 卸载时不做任何“恢复”动作：模块只在本次启动切换了 zram0，
# 重启后系统会按原厂流程重新初始化 zram，压缩算法自然回到 stock 值。
LOG=/data/local/tmp/fuxi_zram_lz4kd.log
echo "=== $(date) uninstall：重启后 zram 自动回到原厂算法 ===" >> "$LOG" 2>&1
