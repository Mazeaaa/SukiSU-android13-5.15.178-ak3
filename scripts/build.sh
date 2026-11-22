#!/usr/bin/env bash
# =============================================================================
# fuxi (Xiaomi 13) GKI 5.15.178 内核构建脚本
#   SukiSU Nova + (可选)SUSFS + (可选)KPM + (可选)LZ4KD(ZRAM 增强)
#
# 基线：AOSP ACK  common-android13-5.15-2025-03  ==  Linux 5.15.178
#
# 用法（套件根目录）：
#   KSU_VERSION=35000 KSU_PKG=com.sukisu.nova WITH_SUSFS=1 WITH_LZ4KD=1 \
#     INJECT_KPM=1 PACK_AK3=1 STOCK_BOOT=/path/stock_boot.img bash scripts/build.sh
#
# 可覆盖变量：
#   WORK            工作目录（默认 ./work，需 >=40GB）
#   OUT             产物目录（默认 ./out）
#   ACK_REF         manifest 分支（默认 common-android13-5.15-2025-03）
#   KERNEL_COMMIT   固定到 stock 对应 commit（uname -r 里的 g<hash> 亦可）
#   KSU_VERSION     必须 = 管理器 APK versionCode（Nova v3.0.0-r1 = 35075）
#   KSU_PKG         管理器包名（Nova = com.sukisu.nova）
#   WITH_SUSFS      1 = builtin + susfs4ksu 内置；0 = main（kprobe）
#   SUSFS_STRICT    1 = SUSFS 补丁失败即中止；0 = 失败回退 main 分支（默认）
#   WITH_LZ4KD      1 = 内置 crypto/lz4kd（默认 1）
#   INJECT_KPM      1 = 构建期注入 KernelPatch kpimg（默认 1）
#   PACK_AK3        1 = 额外产出 AnyKernel3 zip（默认 1）
#   STOCK_BOOT      stock boot.img 路径；给出则继承式重打包（最稳）
#   SKIP_SYNC       1 = 跳过 repo sync
#   BUILD_JOBS      编译并行度（默认 nproc）
# =============================================================================
set -euo pipefail

log() { printf '\n\033[1;32m===== [%s] %s =====\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\n\033[1;33m[WARN] %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- 参数 --------------------------------------------------------------------
: "${KSU_VERSION:=35075}"
: "${KSU_PKG:=com.sukisu.nova}"
: "${WITH_SUSFS:=1}"
: "${SUSFS_STRICT:=0}"
: "${WITH_LZ4KD:=1}"
: "${INJECT_KPM:=1}"
: "${PACK_AK3:=1}"
: "${SKIP_SYNC:=0}"
: "${ACK_REF:=common-android13-5.15-2025-03}"
: "${KERNEL_COMMIT:=}"
: "${STOCK_BOOT:=}"
: "${BUILD_JOBS:=$(nproc)}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${WORK:=$BASE_DIR/work}"
: "${OUT:=$BASE_DIR/out}"

KERNEL_MANIFEST="https://android.googlesource.com/kernel/manifest"
KSU_REPO="https://github.com/SukiSU-Nova/SukiSU-Nova"
SUSFS_REPO="https://gitlab.com/simonpunk/susfs4ksu"
SUSFS_MIRROR="https://github.com/jiekaai/fuxi-susfs"
SUSFS_BRANCH="gki-android13-5.15"
LZ4KD_REPO="https://github.com/lava114514/lz4kd-lkm"
LZ4KD_REF="main"
KP_VER="0.14.0"
KP_BASE="https://github.com/SukiSU-Nova/SukiSU_KernelPatch_patch/releases/download/${KP_VER}"


# ---- 通用的“克隆不成改下 tarball”逻辑（国内网络 clone 常常 TCP 被掐） -------
fetch_repo() {  # $1=url $2=ref $3=dest
  local url="$1" ref="$2" dest="$3" tb
  rm -rf "$dest"
  if git clone --depth 1 --branch "$ref" "$url" "$dest" 2>/dev/null; then
    return 0
  fi
  case "$url" in
    *github.com/*) tb="https://codeload.github.com/${url#https://github.com/}/tar.gz/refs/heads/$ref" ;;
    *gitlab.com/*) tb="${url}/-/archive/${ref}/${url##*/}-${ref}.tar.gz" ;;
    *) return 1 ;;
  esac
  warn "git clone 失败，改用 tarball: $tb"
  mkdir -p "$dest"
  curl -fL --retry 3 --connect-timeout 20 --max-time 900 -o "$dest/.src.tar.gz" "$tb" || return 1
  tar -xzf "$dest/.src.tar.gz" -C "$dest" --strip-components=1 || return 1
  rm -f "$dest/.src.tar.gz"
  return 0
}

mkdir -p "$OUT"
log "fuxi 5.15.178 构建开始"
log "KSU=$KSU_PKG/$KSU_VERSION SUSFS=$WITH_SUSFS LZ4KD=$WITH_LZ4KD KPM=$INJECT_KPM AK3=$PACK_AK3"
log "ACK_REF=$ACK_REF KERNEL_COMMIT=${KERNEL_COMMIT:-<branch tip>}"
log "WORK=$WORK OUT=$OUT"

# ---- 1. repo sync ------------------------------------------------------------
# CI（GitHub Actions / 全新机器）走这条；本地已有源码时设 SKIP_SYNC=1 跳过。
# googlesource 偶尔会掐大 pack（GnuTLS recv error -110），所以带重试 + 逐次降并发。
sync_once() { ( cd "$WORK" && repo sync -c -j"$1" --no-clone-bundle --retry-fetches=3 ${2:-} ); }

# kernel/common 把月度分支归档成 deprecated/xxx，manifest 里仍写旧名 → 首次 sync 必然失败
fix_manifest_revision() {
  local mani="$WORK/.repo/manifests/default.xml"
  [ -f "$mani" ] || return 0
  if grep -q '="android13-5\.15-2025-03"' "$mani"; then
    log "修正 manifest：android13-5.15-2025-03 -> deprecated/android13-5.15-2025-03"
    sed -i 's#="android13-5\.15-2025-03"#="deprecated/android13-5.15-2025-03"#g' "$mani"
  fi
}

if [ "$SKIP_SYNC" = "1" ]; then
  log "SKIP_SYNC=1，跳过同步"
else
  if [ ! -d "$WORK/.repo" ]; then
    log "初始化 kernel/manifest"
    mkdir -p "$WORK"
    # 先单独确认能连上 googlesource，避免把网络故障误报成"分支不存在"
    MANI_REFS="$(git ls-remote "$KERNEL_MANIFEST" 2>/dev/null)" ||
      die "无法访问 $KERNEL_MANIFEST（网络/DNS 问题，不是分支问题）"
    printf '%s\n' "$MANI_REFS" | awk '{print $2}' | sed -n 's#^refs/heads/##p' | grep -Fx "$ACK_REF" >/dev/null ||
      die "manifest 里没有分支 $ACK_REF（\`git ls-remote $KERNEL_MANIFEST\` 可查看现有分支）"
    log "manifest ref: $ACK_REF"
    ( cd "$WORK" && repo init -u "$KERNEL_MANIFEST" -b "$ACK_REF" --no-repo-verify ) ||
      die "repo init 失败"
  else
    log "复用已有 repo（断点续传）"
  fi
  fix_manifest_revision

  SYNC_OK=0
  for attempt in 1 2 3; do
    case "$attempt" in
      1) jobs="$BUILD_JOBS"; extra="" ;;
      2) jobs=4;             extra="--force-sync" ;;
      *) jobs=1;             extra="--force-sync --fail-fast" ;;
    esac
    log "repo sync 第 $attempt 次（-j$jobs ${extra:-}）"
    if sync_once "$jobs" "$extra"; then SYNC_OK=1; break; fi
    warn "  repo sync 第 $attempt 次失败"
    sleep $((attempt * 15))
  done

  if [ "$SYNC_OK" != "1" ]; then
    # 只补 common 也能救急（CI 上常见于 build/prebuilts 已就位、common 单独失败）
    warn "repo sync 三次都失败，尝试单独补 common"
    fetch_repo "https://android.googlesource.com/kernel/common" \
               "deprecated/android13-5.15-2025-03" "$WORK/common" ||
      warn "  单独拉 common 也失败"
  fi
  [ -d "$WORK/common" ] || die "repo sync 未完成（缺 $WORK/common）。可先手动 repo sync，再用 SKIP_SYNC=1 重跑"
  for d in build prebuilts; do
    [ -d "$WORK/$d" ] || die "缺 $WORK/$d：GKI 构建脚本和工具链不完整，repo sync 没跑完"
  done
fi

[ -d "$WORK/common" ] || die "缺少 $WORK/common，源码未就绪"
KERNEL_DIR="$WORK/common"

if [ -n "$KERNEL_COMMIT" ]; then
  log "checkout $KERNEL_COMMIT"
  git -C "$KERNEL_DIR" checkout -q "$KERNEL_COMMIT" ||
    die "checkout $KERNEL_COMMIT 失败（commit 可能不在本分支）"
fi
log "内核源码 HEAD = $(git -C "$KERNEL_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
KVER="$(awk '/^VERSION/{v=$3}/^PATCHLEVEL/{p=$3}/^SUBLEVEL/{s=$3}END{print v"."p"."s}' "$KERNEL_DIR/Makefile")"
log "源码版本：$KVER（目标 5.15.178）"
[ "$KVER" = "5.15.178" ] || warn "版本不是 5.15.178，CRC 可能与 stock 有偏差"

# ---- 1.5 还原内核树到干净 HEAD（补丁每次都从零打） --------------------------
if git -C "$KERNEL_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  log "还原内核树：git reset --hard + clean（丢弃上次的补丁残留）"
  git -C "$KERNEL_DIR" reset --hard -q HEAD 2>/dev/null || true
  git -C "$KERNEL_DIR" clean -fdq 2>/dev/null || true
fi

# ---- 2. LZ4KD（ZRAM 增强压缩算法） -------------------------------------------
if [ "$WITH_LZ4KD" = "1" ]; then
  log "LZ4KD：克隆 $LZ4KD_REPO ($LZ4KD_REF)"
  fetch_repo "$LZ4KD_REPO" "$LZ4KD_REF" "$WORK/lz4kd-src" || die "LZ4KD 源码获取失败"
  python3 "$BASE_DIR/scripts/lz4kd_setup.py" "$KERNEL_DIR" "$WORK/lz4kd-src/kernel/src"
else
  log "WITH_LZ4KD=0，跳过"
fi

# ---- 3. SUSFS 内核补丁（先打，决定 KSU 用哪个分支） --------------------------
SUSFS_APPLIED=0
if [ "$WITH_SUSFS" = "1" ]; then
  log "SUSFS：克隆 susfs4ksu（$SUSFS_BRANCH）"
  fetch_repo "$SUSFS_REPO" "$SUSFS_BRANCH" "$WORK/susfs4ksu" ||
    { warn "gitlab 失败，改用镜像 $SUSFS_MIRROR"; fetch_repo "$SUSFS_MIRROR" "$SUSFS_BRANCH" "$WORK/susfs4ksu"; } ||
    { [ "$SUSFS_STRICT" = "1" ] && die "SUSFS 源码不可用"; warn "SUSFS 源码不可用，回退 main 分支"; }

  PATCH_FILE="$WORK/susfs4ksu/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"
  if [ -f "$PATCH_FILE" ]; then
    cp -a "$WORK/susfs4ksu/kernel_patches/fs/." "$KERNEL_DIR/fs/" 2>/dev/null || true
    cp -a "$WORK/susfs4ksu/kernel_patches/include/linux/." "$KERNEL_DIR/include/linux/" 2>/dev/null || true
    if patch -p1 --dry-run -d "$KERNEL_DIR" < "$PATCH_FILE" >/dev/null 2>&1; then
      log "SUSFS 补丁上下文完全匹配，正式应用"
      patch -p1 -d "$KERNEL_DIR" < "$PATCH_FILE" || die "SUSFS 补丁应用失败"
      SUSFS_APPLIED=1
    else
      log "SUSFS 补丁 dry-run 不匹配，fuzz 应用后用本地修补补齐"
      patch -p1 -l -F3 -d "$KERNEL_DIR" < "$PATCH_FILE" || true

      # fs/namespace.c 的 include hunk 必然失败（官方上下文含高通独有的
      # #include <trace/hooks/blk.h>）。用锚点插入补齐，成功后删掉这个 .rej，
      # 否则它会让下面的“残留 .rej 计数”误判为补丁失败。
      if python3 "$BASE_DIR/scripts/susfs_namespace_fix.py" "$KERNEL_DIR"; then
        rm -f "$KERNEL_DIR"/fs/namespace.c.rej
        NS_FIXED=1
      else
        NS_FIXED=0
        warn "  fs/namespace.c 本地修补失败（锚点未找到）"
      fi
      # 校验两个插入点确实落地（防止脚本自称成功但内容没进去）
      if [ "$NS_FIXED" = "1" ] &&
         grep -q 'susfs_def.h' "$KERNEL_DIR/fs/namespace.c" &&
         grep -q 'CL_COPY_MNT_NS BIT(25)' "$KERNEL_DIR/fs/namespace.c"; then
        log "  fs/namespace.c 已补齐 susfs include / SUS_MOUNT 声明"
      else
        NS_FIXED=0
      fi

      REJS="$(find "$KERNEL_DIR" -name '*.rej' | wc -l)"
      find "$KERNEL_DIR" -name '*.rej' -delete
      find "$KERNEL_DIR" -name '*.orig' -delete
      if [ "$NS_FIXED" = "1" ] && [ "$REJS" = "0" ]; then
        SUSFS_APPLIED=1
        log "SUSFS 全部 hunk 就位（官方补丁 + 本地修补）"
      else
        warn "SUSFS 补丁未完全就位（残留 .rej=$REJS，namespace 修补=$NS_FIXED）"
        # 回滚必须覆盖官方补丁碰过的所有目录：block/ 与 drivers/input/ 也在其中，
        # 漏掉它们会让半应用状态留到下一轮，下一轮就变成 "Reversed patch detected"。
        git -C "$KERNEL_DIR" checkout -- \
          block drivers/input fs include kernel mm security 2>/dev/null || true
        git -C "$KERNEL_DIR" clean -fdq \
          block drivers/input fs include kernel mm security 2>/dev/null || true
        [ "$SUSFS_STRICT" = "1" ] && die "SUSFS_STRICT=1：中止"
        warn "SUSFS: patch failed -> 回退 main 分支（无内置 SUSFS）"
      fi
    fi
  else
    warn "找不到 $PATCH_FILE"
    [ "$SUSFS_STRICT" = "1" ] && die "缺 SUSFS 补丁文件"
  fi
fi

# ---- 4. SukiSU Nova ---------------------------------------------------------
KSU_BRANCH="main"
[ "$SUSFS_APPLIED" = "1" ] && KSU_BRANCH="builtin"

log "克隆 SukiSU Nova（$KSU_BRANCH）"
rm -rf "$WORK/ksu-src"
fetch_repo "$KSU_REPO" "$KSU_BRANCH" "$WORK/ksu-src" || die "Nova 源码获取失败"

log "kernel/ -> drivers/kernelsu"
rm -rf "$KERNEL_DIR/drivers/kernelsu"
cp -a "$WORK/ksu-src/kernel" "$KERNEL_DIR/drivers/kernelsu"

# 上游 uapi 在不同分支形态不同：main 是真实目录，builtin 是相对符号链接
# `uapi -> ./kernel/include/uapi`。直接 cp -a 会把链接原样搬过去、指到不存在
# 的 include/kernel/include/uapi，所以要先解析真实路径再逐文件复制。
log "修复 kernelsu 的 uapi 头（真实目录替换符号链接）"
UAPI_SRC="$WORK/ksu-src/uapi"
UAPI_REAL="$(readlink -f "$UAPI_SRC" 2>/dev/null || echo "$UAPI_SRC")"
if [ -d "$UAPI_REAL" ] && [ "$UAPI_REAL" != "$UAPI_SRC" ]; then
  log "  uapi 是指向 $UAPI_REAL 的链接，按真实目录处理"
  UAPI_SRC="$UAPI_REAL"
fi
[ -d "$UAPI_SRC" ] || die "找不到 uapi 头目录（$WORK/ksu-src/uapi）"
rm -rf "$KERNEL_DIR/drivers/kernelsu/include/uapi"
mkdir -p "$KERNEL_DIR/drivers/kernelsu/include/uapi"
cp -a "$UAPI_SRC/." "$KERNEL_DIR/drivers/kernelsu/include/uapi/"
for h in app_profile.h ksu.h supercall.h; do
  [ -f "$KERNEL_DIR/drivers/kernelsu/include/uapi/$h" ] || die "uapi 复制失败：缺 $h"
done

grep -q 'kernelsu' "$KERNEL_DIR/drivers/Makefile" ||
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$KERNEL_DIR/drivers/Makefile"
grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig" ||
  printf '\nsource "drivers/kernelsu/Kconfig"\n' >> "$KERNEL_DIR/drivers/Kconfig"

log "固定 KSU_VERSION=$KSU_VERSION / KSU_PACKAGE_NAME=$KSU_PKG"
# main 分支用 Kbuild，builtin 分支只有 Makefile（KSU_VERSION 由 commit 数推算）。
# 两者都要能把版本号钉死，否则管理器会判版本不匹配。
KSU_MK="$KERNEL_DIR/drivers/kernelsu/Kbuild"
[ -f "$KSU_MK" ] || KSU_MK="$KERNEL_DIR/drivers/kernelsu/Makefile"
[ -f "$KSU_MK" ] || die "drivers/kernelsu 下既无 Kbuild 也无 Makefile，源码结构异常"
log "  版本注入目标：${KSU_MK#$KERNEL_DIR/}"
python3 "$BASE_DIR/scripts/patch_ksu_version.py" \
  "$KSU_MK" "$KSU_VERSION" "$KSU_PKG" "v${KSU_VERSION}-${KSU_BRANCH:-builtin}@fuxi" ||
  die "版本号写入失败（Nova 的构建文件结构可能已变）"
grep -qE "^KSU_VERSION\s*:?=\s*$KSU_VERSION$" "$KSU_MK" ||
  warn "  版本号未按预期落地，请检查 $KSU_MK"

# builtin 分支不走 kprobe，必须注入 4 个手工 hook，否则 root 完全不工作
if [ "$KSU_BRANCH" = "builtin" ]; then
  log "builtin 分支手工 hook（execve / faccessat / newfstatat / reboot）"
  python3 "$BASE_DIR/scripts/apply_hooks.py" "$KERNEL_DIR" ||
    die "hook 注入失败：builtin 内核没有 hook 无法授权 root。请改用 WITH_SUSFS=0 重新构建"
fi

# ---- 5. 追加 config（只追加，绝不删改 stock 项） -----------------------------
log "追加 KSU/KPM config"
cat "$BASE_DIR/configs/fuxi-ksu.config" >> "$KERNEL_DIR/arch/arm64/configs/gki_defconfig"

if [ "$SUSFS_APPLIED" = "1" ]; then
  log "追加 SUSFS config"
  cat "$BASE_DIR/configs/fuxi-susfs.config" >> "$KERNEL_DIR/arch/arm64/configs/gki_defconfig"
fi

if [ "$WITH_LZ4KD" = "1" ]; then
  log "追加 LZ4KD/ZRAM config"
  cat "$BASE_DIR/configs/fuxi-zram.config" >> "$KERNEL_DIR/arch/arm64/configs/gki_defconfig"
fi

# ---- 5.5 LTO 模式（Full LTO 在 14 线程上是单线程链接，一小时起步） ----------
LTO_MODE="${LTO_MODE:-thin}"
if [ "$LTO_MODE" = "thin" ]; then
  DEFCONF="$KERNEL_DIR/arch/arm64/configs/gki_defconfig"
  if grep -q '^CONFIG_LTO_CLANG_FULL=y' "$DEFCONF"; then
    log "LTO: FULL -> THIN（并行链接、省内存；不影响 ABI/CRC）"
    sed -i 's/^CONFIG_LTO_CLANG_FULL=y/# CONFIG_LTO_CLANG_FULL is not set/' "$DEFCONF"
  fi
  grep -q '^CONFIG_LTO_CLANG_THIN=y' "$DEFCONF" || printf '\nCONFIG_LTO_CLANG_THIN=y\n' >> "$DEFCONF"
else
  log "LTO: 保持 FULL（$LTO_MODE）"
fi

# ---- 6. 编译 ----------------------------------------------------------------
if [ -x "$WORK/build/build.sh" ]; then
  BUILD_SH="$WORK/build/build.sh"
elif [ -x "$WORK/common/build/build.sh" ]; then
  BUILD_SH="$WORK/common/build/build.sh"
else
  die "找不到 build/build.sh"
fi

log "清理补丁残留（*.orig / *.rej）"
find "$KERNEL_DIR" -name '*.orig' -delete 2>/dev/null || true
find "$KERNEL_DIR" -name '*.rej' -delete 2>/dev/null || true

# 用 GKI_BUILD_CONFIG_FRAGMENT 关掉 defconfig 一致性校验与 KMI 强制检查
export GKI_BUILD_CONFIG_FRAGMENT="$BASE_DIR/configs/fragment.fuxi"
log "GKI_BUILD_CONFIG_FRAGMENT=$GKI_BUILD_CONFIG_FRAGMENT"

log "开始编译（BUILD_CONFIG=common/build.config.gki.aarch64, -j$BUILD_JOBS）"
set +e
( cd "$WORK" && BUILD_CONFIG=common/build.config.gki.aarch64 "$BUILD_SH" 2>&1 | tee "$OUT/build.log" )
BUILD_RC=$?
set -e
[ "$BUILD_RC" = "0" ] || warn "构建脚本返回 $BUILD_RC"

IMAGE="$(find "$WORK/out" -path '*/dist/Image' -type f | head -n1 || true)"
[ -n "$IMAGE" ] || { warn "out 目录预览："; find "$WORK/out" -maxdepth 4 -name 'Image*' | head -20;
                    tail -80 "$OUT/build.log" >&2; die "找不到 dist/Image，编译失败"; }
cp -f "$IMAGE" "$OUT/Image"
# 注意：不要用 `|| echo '?'`。pipefail 下 `strings | grep -m1` 会因为 strings 收到
# SIGPIPE 而返回非 0，于是 grep 已经打印的内容后面又被追加一个 '?'。
# 正确做法：`|| true` 保留已捕获的输出，再单独判断是否为空。
KREL="$(strings -a "$OUT/Image" | grep -m1 -E '^Linux version 5\.15\.[0-9]+[- ]' || true)"
[ -n "$KREL" ] || KREL='?'
VERMAGIC="$(strings -a "$OUT/Image" | grep -m1 -E '^5\.15\.[0-9]+.*(SMP|PREEMPT).*aarch64' || true)"
[ -n "$VERMAGIC" ] || VERMAGIC='?'
SUSFS_VER="$(strings -a "$OUT/Image" | grep -oE 'susfs is initialized! version: v[0-9.]+' | head -1 | grep -oE 'v[0-9.]+$' || true)"
[ -n "$SUSFS_VER" ] || SUSFS_VER='n/a'
log "编译成功：$KREL"
log "vermagic：$VERMAGIC"
log "SUSFS：$SUSFS_VER"

for f in .config System.map Module.symvers; do
  p="$(find "$WORK/out" -name "$f" | head -n1 || true)"
  if [ -n "$p" ]; then cp -f "$p" "$OUT/$f"; fi
done

# 关键 CONFIG 自检
if [ -f "$OUT/.config" ]; then
  for c in CONFIG_KSU=y CONFIG_KPM=y CONFIG_LZ4KD=y; do
    if grep -qx "$c" "$OUT/.config"; then log "  [ok] $c"; else warn "  [MISS] $c 未生效"; fi
  done
  if [ "$SUSFS_APPLIED" = "1" ]; then
    if grep -qx 'CONFIG_KSU_SUSFS=y' "$OUT/.config"; then log "  [ok] CONFIG_KSU_SUSFS=y"; else warn "  [MISS] CONFIG_KSU_SUSFS"; fi
  fi
fi

# ---- 7. KPM 注入 ------------------------------------------------------------
BOOT_KERNEL="$OUT/Image"
if [ "$INJECT_KPM" = "1" ]; then
  log "KPM：下载 kptools-linux / kpimg（KernelPatch $KP_VER）"
  curl -fL --retry 3 --connect-timeout 20 --max-time 300 -o "$OUT/kptools-linux" "$KP_BASE/kptools-linux"
  curl -fL --retry 3 --connect-timeout 20 --max-time 300 -o "$OUT/kpimg"        "$KP_BASE/kpimg"
  chmod +x "$OUT/kptools-linux"
  log "KPM：注入宿主"
  "$OUT/kptools-linux" -p -s 123 -i "$OUT/Image" -k "$OUT/kpimg" -o "$OUT/Image.kpm" || die "kptools 注入失败"
  [ -s "$OUT/Image.kpm" ] || die "Image.kpm 为空"
  BOOT_KERNEL="$OUT/Image.kpm"
fi

# ---- 8. 打包 boot.img / AnyKernel3 / ZRAM 模块 ------------------------------
STAMP="$(date +%Y%m%d-%H%M)"
BOOT_IMG="$OUT/boot-fuxi-$STAMP.img"
if [ -n "$STOCK_BOOT" ] && [ -f "$STOCK_BOOT" ]; then
  log "继承式重打包（基准：$STOCK_BOOT）"
  python3 "$BASE_DIR/scripts/repack_boot.py" --stock "$STOCK_BOOT" --kernel "$BOOT_KERNEL" --output "$BOOT_IMG"
else
  log "无 STOCK_BOOT，从零生成 boot header v4（page=4096 / 无 ramdisk）"
  python3 "$BASE_DIR/scripts/pack_bootimg.py" --kernel "$BOOT_KERNEL" --output "$BOOT_IMG"
fi
[ -s "$BOOT_IMG" ] || die "boot.img 打包失败"
log "boot.img: $(basename "$BOOT_IMG") ($(stat -c%s "$BOOT_IMG") bytes)"

python3 - "$BOOT_IMG" <<'PY' > "$OUT/bootimg_info.txt" || warn "boot header 自检失败"
import struct, sys, os
p = sys.argv[1]
b = open(p, 'rb').read(4096)
magic = b[:8].decode()
kernel, ramdisk = struct.unpack_from('<II', b, 8)
hsize, = struct.unpack_from('<I', b, 20)
hver, = struct.unpack_from('<I', b, 40)
sig, = struct.unpack_from('<I', b, 1580) if hver == 4 else (0,)
info = ("magic=%s header_version=%d header_size=%d kernel_size=%d ramdisk_size=%d "
        "signature_size=%d image_size=%d" % (magic, hver, hsize, kernel, ramdisk, sig, os.path.getsize(p)))
print(info)
assert magic == 'ANDROID!' and hver in (3, 4) and ramdisk == 0 and kernel > 0, "header 异常"
PY

if [ "$PACK_AK3" = "1" ]; then
  log "生成 AnyKernel3 zip（扁平结构，同 Wild Kernels 参考包）"
  # 有 AK3_TEMPLATE 就用它当模板（工具版本与参考包完全一致），否则回退 osm0sis 官方仓库
  KSU_VERSION="$KSU_VERSION" KSU_PKG="$KSU_PKG" SUSFS_VER="$SUSFS_VER" \
    bash "$BASE_DIR/scripts/pack_ak3_wild.sh" \
      "$OUT/Image" "$OUT/fuxi-ak3-$STAMP.zip" "${AK3_TEMPLATE:-}" ||
    warn "AnyKernel3 打包失败（不影响 boot.img）"
fi

bash "$BASE_DIR/scripts/pack_module.sh" "$BASE_DIR/modules/fuxi-zram-lz4kd" "$OUT/fuxi-zram-lz4kd-$STAMP.zip" ||
  warn "ZRAM 模块打包失败（不影响内核）"

# ---- 9. 信息与校验和 --------------------------------------------------------
{
  echo "build_time=$(date -u +%FT%TZ)"
  echo "device=fuxi (Xiaomi 13)"
  echo "kernel_base=$ACK_REF / $KVER"
  echo "kernel_commit=$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || echo '?')"
  echo "kernel_release=$KREL"
  echo "vermagic=$VERMAGIC"
  echo "susfs_version=$SUSFS_VER"
  echo "sukisu_branch=$KSU_BRANCH"
  echo "ksu_version=$KSU_VERSION"
  echo "ksu_pkg=$KSU_PKG"
  echo "with_susfs=$WITH_SUSFS susfs_applied=$SUSFS_APPLIED"
  echo "with_lz4kd=$WITH_LZ4KD"
  echo "inject_kpm=$INJECT_KPM"
  echo "boot_img=$(basename "$BOOT_IMG") size=$(stat -c%s "$BOOT_IMG")"
} > "$OUT/BUILD_INFO.txt"

( cd "$OUT" && sha256sum Image boot-fuxi-*.img fuxi-ak3-*.zip fuxi-zram-lz4kd-*.zip 2>/dev/null > SHA256SUMS || true )

log "完成。产物目录：$OUT"
ls -lh "$OUT" | sed -n '1,30p'
cat "$OUT/BUILD_INFO.txt"
