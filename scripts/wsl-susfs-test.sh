#!/usr/bin/env bash
# 只跑 SUSFS 补丁环节，不编译。用于快速验证 patch 是否全部就位。
# 用法：wsl.exe -d fuxi-build -u root -- bash /root/fuxi-kit/scripts/wsl-susfs-test.sh
set -uo pipefail

KIT=/root/fuxi-kit
WORK=/root/fuxi-work
KERNEL_DIR="$WORK/common"
SUSFS_BRANCH="gki-android13-5.15"
PATCH_FILE="$WORK/susfs4ksu/kernel_patches/50_add_susfs_in_${SUSFS_BRANCH}.patch"

step() { echo; echo "===== $* ====="; }

step "0. 还原内核树"
cd "$KERNEL_DIR" || exit 1
git reset --hard -q HEAD && git clean -fdq
find . -name '*.rej' -delete
echo "HEAD=$(git rev-parse --short HEAD)  dirty=$(git status --porcelain | wc -l)"

step "1. 复制 susfs 附属源文件"
cp -a "$WORK/susfs4ksu/kernel_patches/fs/." "$KERNEL_DIR/fs/"
cp -a "$WORK/susfs4ksu/kernel_patches/include/linux/." "$KERNEL_DIR/include/linux/"

step "2. dry-run"
if patch -p1 --dry-run -d "$KERNEL_DIR" < "$PATCH_FILE" >/tmp/dry.log 2>&1; then
  echo "dry-run 全部匹配（意外，预期不匹配）"
else
  echo "dry-run 不匹配，符合预期，前 20 行："
  head -20 /tmp/dry.log
fi

step "3. fuzz 应用"
patch -p1 -l -F3 -d "$KERNEL_DIR" < "$PATCH_FILE" 2>&1 | tail -40

step "4. 本地修补 fs/namespace.c"
python3 "$KIT/scripts/susfs_namespace_fix.py" "$KERNEL_DIR"

step "5. 检查残留 .rej"
REJ_LIST="$(find "$KERNEL_DIR" -name '*.rej')"
if [ -z "$REJ_LIST" ]; then
  echo ">>> 0 个 .rej，SUSFS 补丁全部就位"
else
  echo ">>> 仍有 .rej："
  echo "$REJ_LIST"
  for f in $REJ_LIST; do
    echo "------ $f ------"
    head -40 "$f"
  done
fi

step "6. 关键符号自检"
check() {
  if grep -rqs "$2" "$KERNEL_DIR/$1"; then echo "  [ok]   $1 : $2"; else echo "  [MISS] $1 : $2"; fi
}
check fs/namespace.c "susfs_def.h"
check fs/namespace.c "CL_COPY_MNT_NS"
check block/ioprio.c "susfs_is_priority_uid_filtered"
check drivers/input/input.c "ksu_handle_input_handle_event"
check fs/exec.c "susfs"
check kernel/kallsyms.c "susfs"
check fs/proc/task_mmu.c "susfs"
check security/selinux/hooks.c "susfs"

step "7. 统计"
echo "改动文件数：$(git -C "$KERNEL_DIR" status --porcelain | wc -l)"
