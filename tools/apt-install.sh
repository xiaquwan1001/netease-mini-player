#!/usr/bin/env bash
# CI 用 apt 安装包装: 带重试。
#
# 为什么需要: GitHub 托管的 runner 偶发 DNS 解析失败
# ("Temporary failure resolving 'azure.archive.ubuntu.com'"), 一次就整条流水线红。
# 2026-11-11 v0.5.2 的 Release 因此连挂两次(verify job 的 apt-get install libasound2-dev),
# 与代码无关但会挡住发版 ⇒ 这里做有限次指数退避重试。
#
# 用法: bash tools/apt-install.sh <pkg> [pkg...]
set -uo pipefail

if [ $# -eq 0 ]; then
  echo "用法: $0 <pkg> [pkg...]" >&2
  exit 2
fi

RETRIES=${APT_RETRIES:-5}
for i in $(seq 1 "$RETRIES"); do
  if sudo apt-get update -o Acquire::Retries=3 >/dev/null 2>&1 \
     && sudo apt-get install -y --no-install-recommends -o Acquire::Retries=3 "$@"; then
    echo "[apt] 安装成功: $* (第 $i 次尝试)"
    exit 0
  fi
  echo "[apt] 第 $i 次失败, 稍后重试: $*" >&2
  sleep $((i * 10))
done

echo "[apt] 重试 ${RETRIES} 次仍失败: $*" >&2
exit 1
