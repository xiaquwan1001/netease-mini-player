#!/usr/bin/env bash
# CI 用 apt 安装包装: 带重试 + 镜像兜底。
#
# 为什么需要: GitHub 托管的 runner 偶发 DNS 解析失败
# ("Temporary failure resolving 'azure.archive.ubuntu.com'"), 一次就整条流水线红。
# 2026-11-11 v0.5.2 / v0.5.3 都因此挂掉(verify job 的 apt-get install libasound2-dev),
# 与代码无关但会挡住发版。
#
# 策略: 前两次用 runner 自带源; 之后若还没成功, 追加一份 USTC 镜像源(见 FALLBACK_SOURCES)
# 再重试 —— runner 到 azure.archive.ubuntu.com 的解析会整片挂掉, 但到公共镜像通常正常。
#
# 用法: bash tools/apt-install.sh <pkg> [pkg...]
set -uo pipefail

if [ $# -eq 0 ]; then
  echo "用法: $0 <pkg> [pkg...]" >&2
  exit 2
fi

# 参数清洗: YAML 折叠/续行符会送出带前导空格的包名(" libasound2-dev"),
# apt 报 'Unable to locate package  libasound2-dev'(双空格即此坑), 这里统一 trim。
args=()
for a in "$@"; do
  a="${a#"${a%%[![:space:]]*}"}"
  a="${a%"${a##*[![:space:]]}"}"
  [ -n "$a" ] && args+=("$a")
done
set -- "${args[@]}"

RETRIES=${APT_RETRIES:-6}
FALLBACK_SOURCES=${APT_FALLBACK_SOURCES:-/etc/apt/sources.list.d/minincm-fallback.list}
CODENAME=${APT_CODENAME:-noble}

# 架构决定镜像路径: amd64/arm64 的 Ubuntu 归档是两套独立索引
# (arm64 在 ubuntu-ports 下), 用错路径的表现是 "Unable to locate package"。
# 2026-11-11 的 arm64 腿就是这么挂的(兜底给了 /ubuntu 但 runner 是 arm64)。
ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
  arm64|aarch64) DEFAULT_MIRROR="http://mirrors.ustc.edu.cn/ubuntu-ports" ;;
  *)             DEFAULT_MIRROR="http://mirrors.ustc.edu.cn/ubuntu" ;;
esac
MIRROR=${APT_FALLBACK_MIRROR:-$DEFAULT_MIRROR}
fallback_added=0

# 兜底生效后只信兜底源: runner 自带的 azure/archive 源会继续被 apt 选中下载
# ("Temporary failure resolving 'azure.archive.ubuntu.com'"), 混着用等于没兜底。
APT_SRC_OPTS=()

add_fallback_mirror() {
  [ "$fallback_added" = "1" ] && return 0
  fallback_added=1
  echo "[apt] runner 自带源不可用, 追加兜底镜像: $MIRROR (架构 $ARCH)" >&2
  sudo tee "$FALLBACK_SOURCES" >/dev/null <<EOF
# 由 tools/apt-install.sh 在自带源失败后追加(CI 专用)
deb $MIRROR/ $CODENAME main universe
deb $MIRROR/ $CODENAME-updates main universe
deb $MIRROR/ $CODENAME-security main universe
EOF
}

for i in $(seq 1 "$RETRIES"); do
  if [ "$i" -ge 3 ]; then add_fallback_mirror; fi
  if [ "$fallback_added" = "1" ]; then
    APT_SRC_OPTS=(-o "Dir::Etc::sourcelist=$FALLBACK_SOURCES" -o "Dir::Etc::sourceparts=-" -o APT::Get::List-Cleanup=0)
  else
    APT_SRC_OPTS=()
  fi
  if sudo apt-get update -o Acquire::Retries=3 "${APT_SRC_OPTS[@]}" >/dev/null 2>&1 \
     && sudo apt-get install -y --no-install-recommends -o Acquire::Retries=3 "${APT_SRC_OPTS[@]}" "$@"; then
    echo "[apt] 安装成功: $* (第 $i 次尝试)"
    exit 0
  fi
  echo "[apt] 第 $i 次失败, 稍后重试: $*" >&2
  sleep $((i * 8))
done

echo "[apt] 重试 ${RETRIES} 次仍失败: $*" >&2
exit 1
