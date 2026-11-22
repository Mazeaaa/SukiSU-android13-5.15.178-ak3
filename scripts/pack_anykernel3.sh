#!/usr/bin/env bash
# 生成 AnyKernel3 zip（fuxi / GKI / 无 ramdisk）
#
# 用法：pack_anykernel3.sh <kernel 镜像> <输出 zip> <工作目录>
# 说明：用 osm0sis/AnyKernel3 官方模板（含 arm64 magiskboot/busybox），
#      运行时按槽位就地替换 boot 内核，不碰 init_boot / vendor_boot。
set -euo pipefail

KERNEL="$(cd "$(dirname "${1:?kernel image}")" && pwd)/$(basename "$1")"
OUTZIP="${2:?output zip}"
case "$OUTZIP" in /*|[A-Za-z]:*) ;; *) OUTZIP="$(pwd)/$OUTZIP" ;; esac
WORK="${3:?workdir}"
AK3_REPO="${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}"
AK3_DIR="$WORK/ak3-template"

command -v zip >/dev/null || { echo "[ak3] 需要 zip"; exit 1; }

if [ ! -d "$AK3_DIR/.git" ]; then
  rm -rf "$AK3_DIR"
  git clone --depth 1 "$AK3_REPO" "$AK3_DIR"
else
  git -C "$AK3_DIR" fetch --depth 1 origin HEAD >/dev/null 2>&1 || true
fi

[ -f "$AK3_DIR/tools/ak3-core.sh" ] || { echo "[ak3] 模板结构异常"; exit 1; }

rm -rf "$AK3_DIR/.git" "$AK3_DIR/.github" "$AK3_DIR/README.md"
rm -f "$AK3_DIR"/Image "$AK3_DIR"/zImage "$AK3_DIR"/*.zip

cp -f "$KERNEL" "$AK3_DIR/Image"

cat > "$AK3_DIR/anykernel.sh" <<'AK3EOF'
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers
## fuxi (Xiaomi 13) / GKI boot，无 ramdisk —— 只替换 kernel 段

properties() { '
kernel.string=fuxi SukiSU Nova (5.15.178 + SUSFS/KPM/LZ4KD)
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.verbose=0
device.name1=fuxi
device.name2=2211133C
device.name3=2211133G
device.name4=22127RK46C
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

## boot 分区
BLOCK=/dev/block/bootdevice/by-name/boot;
IS_SLOT_DEVICE=1;
SLOT_SELECT=a;

## fuxi 的 ramdisk 在 init_boot，boot 里没有 ramdisk：
## 关掉 AK3 的 Magisk/KSU ramdisk 检测，只做 kernel 段替换
NO_MAGISK_CHECK=1;

. tools/ak3-core.sh;

## GKI：boot 内无 ramdisk，split 后直接 flash，保留原 cmdline/os_version
split_boot;
flash_boot;
AK3EOF

( cd "$AK3_DIR" && rm -f "$OUTZIP" && zip -q -r9 "$OUTZIP" . -x '*.git*' )

echo "[ak3] 生成 $OUTZIP ($(stat -c%s "$OUTZIP") bytes)"
