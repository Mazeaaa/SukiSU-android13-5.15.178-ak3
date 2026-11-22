#!/usr/bin/env bash
# 产物自检：符号、vermagic、boot 头、AK3 包、ZRAM 模块。
# 用法：bash scripts/verify-artifacts.sh [out 目录] [stock boot.img]
set -uo pipefail

OUT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/out}"
STOCK="${2:-$(cd "$(dirname "$0")/.." && pwd)/device/boot_a_current.img}"

FAIL=0
ok()   { echo "  [ok]   $*"; }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
info() { echo "  [--]   $*"; }

[ -f "$OUT_DIR/Image" ] || { echo "缺少 $OUT_DIR/Image"; exit 1; }
BOOT="$(ls -1t "$OUT_DIR"/boot-fuxi-*.img 2>/dev/null | head -n1)"
AK3="$(ls -1t "$OUT_DIR"/fuxi-ak3-*.zip 2>/dev/null | head -n1)"
ZM="$(ls -1t "$OUT_DIR"/fuxi-zram-*.zip 2>/dev/null | head -n1)"

echo "=== 1. 内核符号（$OUT_DIR/System.map） ==="
if [ -f "$OUT_DIR/System.map" ]; then
  for s in susfs_init susfs_is_current_ksu_domain susfs_is_sdcard_android_data_not_decrypted \
           ksu_handle_execveat ksu_handle_setresuid ksu_is_input_hook_enabled lz4kd_scompress; do
    if grep -qw "$s" "$OUT_DIR/System.map"; then ok "$s"; else bad "缺符号 $s"; fi
  done
else
  bad "没有 System.map，无法校验符号"
fi

echo "=== 2. vermagic / 版本串 ==="
# 只跑一次 strings：Image 有 40MB+，重复调用很慢；
# 另外 `strings | grep -q` 在 pipefail 下会因为 SIGPIPE 误报失败，所以先取到变量再匹配。
IMG_STR="$(strings -a "$OUT_DIR/Image")"

VERMAGIC="$(printf '%s\n' "$IMG_STR" | grep -m1 -E '^5\.15\.[0-9]+.*(SMP|PREEMPT).*aarch64' || true)"
if [ -n "$VERMAGIC" ]; then info "vermagic: $VERMAGIC"; else bad "找不到 vermagic"; fi
case "$VERMAGIC" in
  *modversions*) ok "带 modversions（模块加载会忽略版本段，只比 CRC）" ;;
  *) bad "vermagic 里没有 modversions，厂商 .ko 可能加载失败" ;;
esac

SUSFS_VER="$(printf '%s\n' "$IMG_STR" | grep -oE 'susfs is initialized! version: v[0-9.]+' | head -1 | grep -oE 'v[0-9.]+$' || true)"
if [ -n "$SUSFS_VER" ]; then ok "SUSFS $SUSFS_VER 已初始化"; else bad "Image 里没有 SUSFS 初始化串"; fi

case "$IMG_STR" in
  *KernelSU*) ok "含 KernelSU 代码" ;;
  *) bad "Image 里没有 KernelSU" ;;
esac

if printf '%s\n' "$IMG_STR" | grep -qx 'lz4kd'; then
  ok "含 lz4kd 算法注册名（zram 可 comp_algorithm=lz4kd）"
elif grep -qw lz4kd_scompress "$OUT_DIR/System.map" 2>/dev/null; then
  info "注册名字符串未直接可见，但 System.map 有 lz4kd_scompress"
  ok "LZ4KD 已编入"
else
  bad "找不到 lz4kd"
fi

echo "=== 3. boot 头结构 ==="
if [ -n "$BOOT" ]; then
  python3 - "$BOOT" ${STOCK:+"$STOCK"} <<'PY'
import sys, os, struct
p = sys.argv[1]
b = open(p, 'rb').read(4096)
magic = b[0:8]
ks, rs, osv, hs = struct.unpack_from('<IIII', b, 8)
hv = struct.unpack_from('<I', b, 40)[0]
cmd = b[44:44+512].split(b'\0')[0]
sig = struct.unpack_from('<I', b, 1580)[0]
print(f"  [--]   magic={magic!r} v{hv} header_size={hs} kernel={ks} ramdisk={rs} sig={sig} os=0x{osv:08x}")
fails = []
if magic != b'ANDROID!': fails.append('magic 不是 ANDROID!')
if hv not in (3, 4): fails.append(f'header_version={hv}')
if rs != 0: fails.append(f'ramdisk_size={rs}（GKI boot 应为 0）')
if not (44 <= hs <= 4096): fails.append(f'header_size={hs}')
if len(sys.argv) > 2 and os.path.exists(sys.argv[2]):
    s = open(sys.argv[2], 'rb').read(4096)
    s_hv = struct.unpack_from('<I', s, 40)[0]
    s_cmd = s[44:44+512].split(b'\0')[0]
    s_osv = struct.unpack_from('<I', s, 16)[0]
    if hv != s_hv: fails.append(f'header_version 与 stock 不一致（{hv} vs {s_hv}）')
    if cmd != s_cmd: fails.append(f'cmdline 与 stock 不一致（{cmd!r} vs {s_cmd!r}）')
    if osv != s_osv: fails.append(f'os_version 与 stock 不一致（0x{osv:08x} vs 0x{s_osv:08x}）')
    print(f"  [--]   已与 stock 对比：header_version / cmdline / os_version 均一致"
          if not fails else "  [--]   与 stock 对比发现差异")
for f in fails:
    print(f"  [FAIL] {f}")
sys.exit(1 if fails else 0)
PY
  [ $? -eq 0 ] && ok "boot 头通过" || FAIL=$((FAIL+1))
else
  bad "找不到 boot-fuxi-*.img"
fi

echo "=== 4. AnyKernel3 包 ==="
if [ -n "$AK3" ]; then
  AK_LIST="$(unzip -l "$AK3" 2>/dev/null || true)"
  AK_CONF="$(unzip -p "$AK3" anykernel.sh 2>/dev/null || true)"
  # 兼容两种写法：参考包的 block=boot / is_slot_device=auto，以及写死全路径的旧写法
  case "$AK_CONF" in
    *block=boot*|*"/dev/block/bootdevice/by-name/boot"*) ok "AK3 刷写目标为 boot 分区" ;;
    *) bad "anykernel.sh 里没找到 boot 分区定义" ;;
  esac
  case "$AK_CONF" in
    *is_slot_device=auto*|*IS_SLOT_DEVICE=1*) ok "AK3 会自动识别 A/B 槽位" ;;
    *) bad "anykernel.sh 未启用槽位识别" ;;
  esac
  case "$AK_CONF" in
    *no_magisk_check=1*|*NO_MAGISK_CHECK=1*) ok "已关闭 Magisk ramdisk 检查（boot 无 ramdisk）" ;;
    *) info "未设置 no_magisk_check，boot 无 ramdisk 时可能被误判" ;;
  esac
  case "$AK_LIST" in
    *" Image"*) ok "AK3 内含 Image" ;;
    *) bad "AK3 里没有 Image" ;;
  esac
  case "$AK_LIST" in
    *" boot.img"*) bad "AK3 里同时有 boot.img，可能整包覆盖" ;;
    *) ok "AK3 不含 boot.img（由 magiskboot 重新打包）" ;;
  esac
  case "$AK_LIST" in
    *"tools/magiskboot"*) ok "自带 magiskboot" ;;
    *) bad "缺 tools/magiskboot，刷入会失败" ;;
  esac
fi

echo "=== 5. ZRAM 切换模块 ==="
if [ -n "$ZM" ]; then
  ZM_LIST="$(unzip -l "$ZM" 2>/dev/null || true)"
  ZM_SCRIPT="$(unzip -p "$ZM" post-fs-data.sh 2>/dev/null || true)"
  case "$ZM_LIST" in
    *post-fs-data.sh*) ok "含 post-fs-data.sh（开机前切算法）" ;;
    *) bad "缺 post-fs-data.sh" ;;
  esac
  case "$ZM_SCRIPT" in
    *lz4kd*) ok "脚本里引用了 lz4kd" ;;
    *) bad "脚本没引用 lz4kd" ;;
  esac
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "全部检查通过。"
else
  echo "有 $FAIL 项未通过，请先处理再刷机。"
fi
exit "$FAIL"
