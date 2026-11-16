#!/usr/bin/env bash
# 用 `flutter build linux --release` 的 bundle 打 tar.gz(纯 bundle 归档, 二进制不重链,
# 目录结构原样保留: minincm 靠 /proc/self/exe 找同级的 data/ 与 lib/).
# 用法: bash packaging/linux/build-tarball.sh [输出目录, 默认 dist]
#
# 覆盖变量:
#   BUNDLE=<bundle 目录>   默认 ui/build/linux/<x64|arm64>/release/bundle
#   ARCH=<x64|arm64>       产物文件名里的架构(默认按 uname -m 推断)
#   VER=<版本号>           默认取 ui/pubspec.yaml(tools/ci-gates.sh version)
# 产物: <out>/MiniNCM-<ver>-linux-<arch>.tar.gz(顶层目录是 bundle/)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/dist}

HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64)  FLUTTER_ARCH=x64 ;;
  aarch64|arm64) FLUTTER_ARCH=arm64 ;;
  *) echo "不支持的架构: $HOST_ARCH" >&2; exit 1 ;;
esac
BUNDLE=${BUNDLE:-$ROOT/ui/build/linux/$FLUTTER_ARCH/release/bundle}
FLUTTER_ARCH=${ARCH:-$FLUTTER_ARCH}
[ -x "$BUNDLE/minincm" ] || { echo "缺少 $BUNDLE/minincm, 先跑 flutter build linux --release" >&2; exit 1; }

VER=${VER:-$(bash "$ROOT/tools/ci-gates.sh" version)}
[ -n "$VER" ] || { echo "读不到版本号(ui/pubspec.yaml / VER=)" >&2; exit 1; }

mkdir -p "$OUT"
OUTFILE="$OUT/MiniNCM-${VER}-linux-${FLUTTER_ARCH}.tar.gz"
TOP=$(basename "$BUNDLE")
tar -C "$(dirname "$BUNDLE")" -czf "$OUTFILE" "$TOP"

# 自检: 顶层必须是 bundle/(文档与 release 的用法都按"解压出 bundle/"写)
# 注意: 先落文件再 grep —— `tar -tzf | head -1` 会让 tar 吃 SIGPIPE, pipefail 下假失败。
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
tar -tzf "$OUTFILE" > "$LIST"
FIRST=$(head -1 "$LIST")
case "$FIRST" in
  "$TOP/"*) ;;
  *) echo "ERROR: $OUTFILE 的顶层目录是 '$FIRST', 不是 '$TOP/'" >&2; exit 1 ;;
esac
ls -lh "$OUTFILE"
echo "tar.gz: $OUTFILE"
