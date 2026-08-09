#!/bin/sh
# 安装 git hooks（防止直接 push 到 main）。
# 用法：sh scripts/install-git-hooks.sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

install -m 755 "$repo_root/scripts/git-hooks/pre-push" "$repo_root/.git/hooks/pre-push"

echo "✓ pre-push hook 已安装（禁止直推 main）"
