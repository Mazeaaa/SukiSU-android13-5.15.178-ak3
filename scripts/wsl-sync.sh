#!/usr/bin/env bash
# 排障：把 repo sync 的完整输出写到 /root/sync.log，再用 sed 显示
cd /root/fuxi-work || exit 9
echo "POSIXLY_CORRECT=${POSIXLY_CORRECT:-<unset>}  BASH=$BASH_VERSION"
repo sync -c -j8 --no-clone-bundle --retry-fetches=2 >/root/sync.log 2>&1
rc=$?
echo "SYNC_EXIT=$rc"
total=$(wc -l < /root/sync.log)
echo "--- log 行数: $total ---"
sed -n '1,15p' /root/sync.log
echo "--- 尾部 25 行 ---"
start=$(( total > 25 ? total - 24 : 1 ))
sed -n "${start},\$p" /root/sync.log
ls -d common >/dev/null 2>&1 && echo "common 已就绪"
