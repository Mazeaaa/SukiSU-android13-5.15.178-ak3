#!/usr/bin/env bash
# 在 WSL 构建发行版里安装 ACK 内核编译依赖（以 root 运行）
set -euo pipefail

echo "== apt update =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

echo "== apt install =="
apt-get install -y -qq --no-install-recommends \
  git curl ca-certificates python3 bc bison build-essential flex \
  libelf-dev libssl-dev libncurses-dev rsync unzip zip lz4 ccache \
  xz-utils cpio kmod patch file bsdextrautils

echo "== repo =="
if [ ! -x /usr/local/bin/repo ]; then
  curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo
  chmod +x /usr/local/bin/repo
fi
/usr/local/bin/repo --version

echo "== git config =="
git config --global user.name  "fuxi-kernel-build" 2>/dev/null || true
git config --global user.email "fuxi-kernel-build@localhost" 2>/dev/null || true

echo "== 工具版本 =="
for t in git python3 make gcc flex bison bc lz4 zip; do
  printf "%-10s %s\n" "$t" "$(command -v "$t" || echo MISSING)"
done
gcc --version | head -1
echo "DEPS_OK"
