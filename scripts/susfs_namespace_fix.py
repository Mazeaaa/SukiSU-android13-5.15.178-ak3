#!/usr/bin/env python3
"""补齐 susfs4ksu 官方补丁在 ACK 5.15.178 上唯一失败的 fs/namespace.c include hunk。

失败原因：官方补丁的上下文里有一行 `#include <trace/hooks/blk.h>`，
纯 ACK 的 fs/namespace.c 没有这行（那是高通/厂商加的），所以整个 hunk 打不上。

本脚本直接按锚点插入，幂等：
  1) 在 `#include <linux/mnt_idmapping.h>` 之后插入 susfs_def.h 的 include
  2) 在 `/* Maximum number of mounts in a mount namespace */` 之前插入
     SUS_MOUNT 需要的 extern 声明与 CL_COPY_MNT_NS 宏

用法：susfs_namespace_fix.py <内核树根目录>
"""
import os
import sys

INC_ANCHOR = "#include <linux/mnt_idmapping.h>\n"
INC_BLOCK = """#ifdef CONFIG_KSU_SUSFS
#include <linux/susfs_def.h>
#endif // #ifdef CONFIG_KSU_SUSFS
"""

MOUNT_ANCHOR = "/* Maximum number of mounts in a mount namespace */"
MOUNT_BLOCK = """#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT
extern bool susfs_is_current_ksu_domain(void);
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;

#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT

"""


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = os.path.join(os.path.abspath(sys.argv[1]), "fs", "namespace.c")
    if not os.path.isfile(path):
        print(f"[susfs-fix] 找不到 {path}", file=sys.stderr)
        return 1

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        text = f.read()

    changed = False

    if "susfs_def.h" not in text:
        if INC_ANCHOR not in text:
            print("[susfs-fix] 找不到 mnt_idmapping 的 include 锚点", file=sys.stderr)
            return 1
        text = text.replace(INC_ANCHOR, INC_ANCHOR + INC_BLOCK, 1)
        changed = True

    if "CL_COPY_MNT_NS BIT(25)" not in text:
        if MOUNT_ANCHOR not in text:
            print("[susfs-fix] 找不到 sysctl_mount_max 锚点", file=sys.stderr)
            return 1
        text = text.replace(MOUNT_ANCHOR, MOUNT_BLOCK + MOUNT_ANCHOR, 1)
        changed = True

    if changed:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.write(text)
        print("[susfs-fix] fs/namespace.c 已补齐 susfs include / SUS_MOUNT 声明")
    else:
        print("[susfs-fix] fs/namespace.c 已是目标状态，跳过")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
