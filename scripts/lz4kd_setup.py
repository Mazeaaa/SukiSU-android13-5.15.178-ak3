#!/usr/bin/env python3
"""把 LZ4KD 压缩算法装进内核 crypto/ 子树。

LZ4KD = 华为 LZ4K（针对 4K 页剪裁的 LZ4）+ Delta 跨页差分，注册为 crypto
scomp 算法后，zram 可直接用：
    echo lz4kd > /sys/block/zram0/comp_algorithm

5.15 的 zcomp_available_algorithm() 走 crypto_has_comp()，因此**不需要**改
drivers/block/zram，这也避免了与厂商 zram.ko 的耦合。

用法：lz4kd_setup.py <内核源码根目录> <lz4kd src 目录>
"""
import os
import re
import shutil
import sys

REQUIRED = [
    "Kconfig",
    "Makefile",
    "lz4kd.h",
    "lz4kd_crypto.c",
    "lz4kd_encode.c",
    "lz4kd_encode_delta.c",
    "lz4kd_decode.c",
    "lz4kd_decode_delta.c",
    "lz4kd_private.h",
    "lz4kd_encode_private.h",
]


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    kroot, src = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])

    crypto_dir = os.path.join(kroot, "crypto")
    if not os.path.isdir(crypto_dir):
        print(f"[lz4kd] 找不到 {crypto_dir}", file=sys.stderr)
        return 1
    if not os.path.isdir(src):
        print(f"[lz4kd] 找不到源码目录 {src}", file=sys.stderr)
        return 1

    missing = [f for f in REQUIRED if not os.path.isfile(os.path.join(src, f))]
    if missing:
        print(f"[lz4kd] 源码缺文件: {', '.join(missing)}", file=sys.stderr)
        return 1

    dst = os.path.join(crypto_dir, "lz4kd")
    shutil.rmtree(dst, ignore_errors=True)
    shutil.copytree(src, dst)
    print(f"[lz4kd] 复制 {len(REQUIRED)} 个文件 -> crypto/lz4kd/")

    # ---- crypto/Makefile ----
    mk = os.path.join(crypto_dir, "Makefile")
    text = open(mk, encoding="utf-8", errors="surrogateescape").read()
    if "lz4kd" not in text:
        if not text.endswith("\n"):
            text += "\n"
        text += "\nobj-$(CONFIG_LZ4KD) += lz4kd/\n"
        open(mk, "w", encoding="utf-8", errors="surrogateescape").write(text)
        print("[lz4kd] crypto/Makefile += obj-$(CONFIG_LZ4KD) += lz4kd/")
    else:
        print("[lz4kd] crypto/Makefile 已包含 lz4kd，跳过")

    # ---- crypto/Kconfig：插到最后一个 endmenu 之前（保持在 menu "Crypto API" 内） ----
    kc = os.path.join(crypto_dir, "Kconfig")
    text = open(kc, encoding="utf-8", errors="surrogateescape").read()
    if 'source "crypto/lz4kd/Kconfig"' in text:
        print("[lz4kd] crypto/Kconfig 已包含 lz4kd，跳过")
    else:
        # 5.15 的 crypto/Kconfig 没有 menu/endmenu，而是 `if CRYPTO ... endif`
        idx = text.rfind("endmenu")
        if idx < 0:
            matches = list(re.finditer(r"^endif.*$", text, re.M))
            if matches:
                idx = matches[-1].start()
            else:
                idx = len(text)
        text = text[:idx] + 'source "crypto/lz4kd/Kconfig"\n\n' + text[idx:]
        open(kc, "w", encoding="utf-8", errors="surrogateescape").write(text)
        print("[lz4kd] crypto/Kconfig += source \"crypto/lz4kd/Kconfig\"")

    # ---- 自检：Makefile 里的目标文件与源码一致（处理反斜杠续行） ----
    mksrc = open(os.path.join(dst, "Makefile"), encoding="utf-8", errors="surrogateescape").read()
    mksrc = mksrc.replace("\\\n", " ")
    objs = re.findall(r"^lz4kd-y\s*[:+]?=\s*(.+)$", mksrc, re.M)
    if objs:
        names = [o.strip().replace(".o", ".c") for o in objs[0].split() if o.strip()]
        for n in names:
            if not os.path.isfile(os.path.join(dst, n)):
                print(f"[lz4kd] Makefile 引用了不存在的 {n}", file=sys.stderr)
                return 1
        print(f"[lz4kd] 目标文件自检通过：{' '.join(names)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
