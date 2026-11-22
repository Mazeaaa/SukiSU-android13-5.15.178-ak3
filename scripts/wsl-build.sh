#!/usr/bin/env bash
# 在 WSL(fuxi-build) 里跑完整构建：把套件复制到 ext4 再编译，产物留在 out/
set -euo pipefail

KIT_SRC="/mnt/c/Users/FATE/Desktop/Project/SukiSU Nova"
KIT=/root/fuxi-kit
STOCK="/mnt/c/Users/FATE/Desktop/Project/SukiSU Nova/device/boot_a_current.img"

mkdir -p "$KIT"
rsync -a --delete \
  --exclude '.git' --exclude 'device' --exclude 'work' --exclude 'out' --exclude '__pycache__' \
  "$KIT_SRC/" "$KIT/"
cd "$KIT"

# Windows 侧文件可能带 CRLF，内核构建脚本必须 LF
find "$KIT" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.config' -o -name '*.yml' -o -name 'module.prop' \) \
  -exec sed -i 's/\r$//' {} +
chmod +x scripts/*.sh modules/*/*.sh
echo "[prep] 换行符已规范化为 LF"

export KSU_VERSION="${KSU_VERSION:-35075}"
export KSU_PKG="${KSU_PKG:-com.sukisu.nova}"
export WITH_SUSFS="${WITH_SUSFS:-1}"
export SUSFS_STRICT="${SUSFS_STRICT:-0}"
export WITH_LZ4KD="${WITH_LZ4KD:-1}"
export INJECT_KPM="${INJECT_KPM:-0}"
export PACK_AK3="${PACK_AK3:-1}"
export WORK=/root/fuxi-work
export OUT=/root/fuxi-kit/out
export BUILD_JOBS="${BUILD_JOBS:-12}"
export SKIP_SYNC="${SKIP_SYNC:-1}"
if [ -f "$STOCK" ]; then export STOCK_BOOT="$STOCK"; fi

echo "=== 参数 ==="
echo "KIT=$KIT WORK=$WORK OUT=$OUT"
env | grep -E '^(KSU_|WITH_|INJECT_|PACK_|SUSFS_|STOCK_BOOT|BUILD_JOBS)' | sort

bash scripts/build.sh
