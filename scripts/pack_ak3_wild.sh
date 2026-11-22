#!/usr/bin/env bash
# 按 Wild Kernels / KernelSU 那两个参考包的“扁平结构”打 AnyKernel3。
#
# 与 osm0sis 原版默认产物的区别（也就是参考包的样子）：
#   - Image 直接放 zip 根目录，没有 patch/ 、modules/ 目录
#   - anykernel.sh 用 block=boot + is_slot_device=auto（不是写死 by-name 全路径）
#   - do.modules=0 / do.systemless=0 / no_magisk_check=1
#   - split_boot 后如果没 ramdisk.cpio 就走 flash_boot（fuxi 的 GKI boot 就是这种）
#
# 用法：
#   bash scripts/pack_ak3_wild.sh <Image> <输出zip> [模板zip]
#   TEMPLATE_ZIP=/path/to/ref.zip bash scripts/pack_ak3_wild.sh ...
set -euo pipefail

KERNEL="${1:?用法: pack_ak3_wild.sh <Image> <out.zip> [template.zip]}"
OUTZIP="${2:?缺少输出 zip 路径}"
TEMPLATE_ZIP="${3:-${TEMPLATE_ZIP:-}}"

KSU_VER="${KSU_VERSION:-35079}"
KSU_PKG="${KSU_PKG:-com.sukisu.nova}"
SUSFS_VER="${SUSFS_VER:-v2.4.0}"

make_abs() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$(pwd)" "$1" ;;
  esac
}
KERNEL="$(make_abs "$KERNEL")"
OUTZIP="$(make_abs "$OUTZIP")"
[ -f "$KERNEL" ] || { echo "[ak3] 找不到内核镜像：$KERNEL" >&2; exit 1; }
mkdir -p "$(dirname "$OUTZIP")"
rm -f "$OUTZIP"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STAGE="$TMP/ak3"
mkdir -p "$STAGE"

# ---- 取模板：优先用参考包（工具版本与它完全一致），否则回退 osm0sis 官方仓库 ----
if [ -n "$TEMPLATE_ZIP" ] && [ -f "$TEMPLATE_ZIP" ]; then
  echo "[ak3] 模板：$TEMPLATE_ZIP"
  unzip -q "$TEMPLATE_ZIP" -d "$STAGE"
  rm -f "$STAGE/Image" "$STAGE/boot.img" "$STAGE/zImage" "$STAGE/dtb"
else
  echo "[ak3] 没有模板包，回退 osm0sis/AnyKernel3"
  ( cd "$TMP" && git clone --depth 1 https://github.com/osm0sis/AnyKernel3.git ak3-src >/dev/null 2>&1 ) \
    || { echo "[ak3] 克隆 AnyKernel3 失败" >&2; exit 1; }
  cp -a "$TMP/ak3-src/LICENSE" "$TMP/ak3-src/META-INF" "$TMP/ak3-src/tools" "$STAGE/"
  [ -f "$TMP/ak3-src/banner" ] && cp -a "$TMP/ak3-src/banner" "$STAGE/"
  rm -f "$STAGE/tools/ak3-core.sh.orig"
fi

for need in META-INF/com/google/android/update-binary tools/ak3-core.sh; do
  [ -e "$STAGE/$need" ] || { echo "[ak3] 模板缺少 $need（这个 zip 不是 AK3？）" >&2; exit 1; }
done

# ---- 内核镜像 + banner ----
cp -f "$KERNEL" "$STAGE/Image"
cat > "$STAGE/banner" <<'BANNER'
   _____ __ __ __ __  __ ____  __  __
  / ___/|  |  |  |  |/ // __ \|  |/  /
  \__ \ |  |  |  |    <|  __/|     <
 ___/ / |  |__|  |  |  \\  \  |  |\  \
/____/  |____/|__|__|__\\____/|__| \__\
        N O V A   ·   f u x i
BANNER

# ---- anykernel.sh（结构照参考包，文案换成本构建的说明）----
cat > "$STAGE/anykernel.sh" <<AK3
### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=SukiSU Nova ${KSU_VER} + SUSFS ${SUSFS_VER} + LZ4KD by workbuddy
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
do.check_boot_version=0
device.name1=
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
keycheck.timeout=10
'; } # end properties


### AnyKernel install
## boot shell variables
block=boot
is_slot_device=auto
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=1

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

# GKI check
kernel_version=\$(cat /proc/version | awk -F '-' '{print \$1}' | awk '{print \$3}')
case \$kernel_version in
    5.10*) ksu_supported=true ;;
    5.15*) ksu_supported=true ;;
    6.1*) ksu_supported=true ;;
    6.6*) ksu_supported=true ;;
    6.12*) ksu_supported=true ;;
    *) ksu_supported=false ;;
esac

ui_print " " "  -> GKI 2.0 Supported: \$ksu_supported"
\$ksu_supported || abort "  -> Non-GKI device, abort."

# boot install
split_boot

if [ -f "\$SPLITIMG/ramdisk.cpio" ]; then
    unpack_ramdisk
    write_boot
else
    flash_boot
fi

ui_print " "
ui_print "SukiSU Nova manager package: ${KSU_PKG}"
ui_print "Kernel KSU_VERSION: ${KSU_VER}"
ui_print "  -> manager APK must have the SAME versionCode (${KSU_VER})"
ui_print "SUSFS: ${SUSFS_VER} built-in (no external .ko needed)"
ui_print "ZRAM: lz4kd compiled in; flash fuxi-zram-lz4kd module to auto-switch"
ui_print " "
ui_print "Version mismatch? rebuild with:"
ui_print "  KSU_VERSION=<manager APK versionCode> bash scripts/build.sh"
ui_print " "
AK3

# ---- 打包：文件顺序按字典序，与参考包一致 ----
( cd "$STAGE" \
  && find . -type f | sed 's|^\./||' | LC_ALL=C sort > "$TMP/list.txt" \
  && zip -q -X -9 -@ "$OUTZIP" < "$TMP/list.txt" )

echo "[ak3] 输出 $OUTZIP ($(stat -c %s "$OUTZIP") bytes)"
echo "[ak3] 内含 $(unzip -l "$OUTZIP" | tail -1 | awk '{print $2}') 个文件"
