#!/usr/bin/env python3
"""把 KSU_VERSION / KSU_PACKAGE_NAME 固定进 SukiSU Nova 的构建文件。

离线 in-tree 构建时版本号会退化：builtin 分支的 Makefile 用「main 分支 commit 数」
推算 KSU_VERSION，而 KSU_VERSION_FULL 里的 tag 会取到**内核树**的 git describe
（变成 vandroid13-5.15-2025-03_r13-xxxx 这种，管理器 About 页显示很难看）。

用法：patch_ksu_version.py <Kbuild|Makefile> <version> <package_name> [version_full]
"""
import re
import sys


def main() -> int:
    if len(sys.argv) < 4 or len(sys.argv) > 5:
        print("usage: patch_ksu_version.py <Kbuild|Makefile> <version> <package_name> [version_full]",
              file=sys.stderr)
        return 2
    path, version, pkg = sys.argv[1], sys.argv[2], sys.argv[3]
    version_full = sys.argv[4] if len(sys.argv) == 5 else None
    src = open(path, "r", encoding="utf-8").read()
    lines = src.splitlines()

    version_re = re.compile(r"^\s*KSU_VERSION\s*[:?]?=.*$")
    full_re = re.compile(r"^\s*KSU_VERSION_FULL\s*[:?]?=.*$")
    pkg_re = re.compile(r"^\s*KSU_PACKAGE_NAME\s*[:?]?=.*$")
    cc_version_re = re.compile(r"^\s*ccflags-y\s*\+=\s*-DKSU_VERSION=")
    cc_pkg_re = re.compile(r"^\s*ccflags-y\s*\+=\s*-DKSU_PACKAGE_NAME=")

    out, has_ver, has_pkg, has_full = [], False, False, False
    for line in lines:
        # 注意顺序：KSU_VERSION_FULL 必须先判断，否则会被 version_re 的 * 吃掉一部分
        if full_re.match(line):
            if version_full:
                out.append(f'KSU_VERSION_FULL := {version_full}')
                has_full = True
            else:
                out.append(line)
        elif version_re.match(line):
            out.append(f"KSU_VERSION := {version}")
            has_ver = True
        elif pkg_re.match(line):
            out.append(f"KSU_PACKAGE_NAME ?= {pkg}")
            has_pkg = True
        else:
            out.append(line)

    def insert_before(predicate, newline):
        for i, line in enumerate(out):
            if predicate(line):
                out.insert(i, newline)
                return True
        return False

    if not has_ver:
        if not insert_before(cc_version_re.match, f"KSU_VERSION := {version}"):
            print("[patch_ksu_version] 找不到 KSU_VERSION 定义位置，构建文件结构可能已变化",
                  file=sys.stderr)
            return 1
    if not has_pkg:
        if not insert_before(cc_pkg_re.match, f"KSU_PACKAGE_NAME ?= {pkg}"):
            print("[patch_ksu_version] 找不到 KSU_PACKAGE_NAME 定义位置", file=sys.stderr)
            return 1
    if version_full and not has_full:
        print("[patch_ksu_version] 未找到 KSU_VERSION_FULL 行，跳过（只影响显示）", file=sys.stderr)

    open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
    msg = f"[patch_ksu_version] KSU_VERSION={version} KSU_PACKAGE_NAME={pkg}"
    if version_full:
        msg += f" FULL={version_full}"
    print(f"{msg} -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
