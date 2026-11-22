#!/usr/bin/env bash
# 把 modules/<id>/ 打包成管理器（KSU / APatch / Magisk）可刷的 zip
# 用法：pack_module.sh <模块目录> <输出 zip>
set -euo pipefail

SRC="$(cd "${1:?module dir}" && pwd)"
OUTZIP="${2:?output zip}"
case "$OUTZIP" in /*|[A-Za-z]:*) ;; *) OUTZIP="$(pwd)/$OUTZIP" ;; esac

command -v zip >/dev/null || { echo "[module] 需要 zip"; exit 1; }
[ -f "$SRC/module.prop" ] || { echo "[module] 缺少 module.prop"; exit 1; }

rm -f "$OUTZIP"
( cd "$SRC" && zip -q -r9 "$OUTZIP" . -x '*.git*' -x '.DS_Store' )
echo "[module] 生成 $OUTZIP ($(stat -c%s "$OUTZIP") bytes)"
