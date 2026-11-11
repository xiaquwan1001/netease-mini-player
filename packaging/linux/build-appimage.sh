#!/usr/bin/env bash
# 用 `flutter build linux --release` 的 bundle 打 AppImage.
# 用法: bash packaging/linux/build-appimage.sh [输出目录, 默认 dist]
#
# 需要 appimagetool: 优先 PATH, 其次 $APPIMAGETOOL, 最后自动下载到 ~/.cache/minincm-packaging.
# CI/无 FUSE 环境自动用 --appimage-extract-and-run(等效 APPIMAGE_EXTRACT_AND_RUN=1).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/dist}

# 架构: bundle 目录用 Flutter 的命名(x64 / arm64), AppImage 用发行名(x86_64 / aarch64)。
# 默认按本机推断(arm64 包必须在 arm64 机器上原生构建); 需要时用 APPIMAGE_ARCH / BUNDLE 覆盖。
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64)  FLUTTER_ARCH=x64;   DEFAULT_APPIMAGE_ARCH=x86_64 ;;
  aarch64|arm64) FLUTTER_ARCH=arm64; DEFAULT_APPIMAGE_ARCH=aarch64 ;;
  *) echo "不支持的架构: $HOST_ARCH" >&2; exit 1 ;;
esac
BUNDLE=${BUNDLE:-$ROOT/ui/build/linux/$FLUTTER_ARCH/release/bundle}
[ -x "$BUNDLE/minincm" ] || { echo "缺少 $BUNDLE/minincm, 先跑 flutter build linux --release" >&2; exit 1; }

# 架构交叉校验: bundle 里 minincm 的 ELF 架构必须与目标 AppImage 架构一致。
# (APPIMAGE_ARCH/BUNDLE 可被覆盖, 组合错了会打出"x86_64 内容的 aarch64.AppImage"。)
# 用 readelf -h 的 Machine 字段判断, bash 3.2 兼容(不用关联数组)。
if command -v readelf >/dev/null 2>&1; then
  # LC_ALL=C: 本地化的 readelf 字段名(如"系统架构")不可解析
  ELF_MACHINE=$(LC_ALL=C readelf -h "$BUNDLE/minincm" | sed -n 's/^ *Machine: *//p' | head -1)
  if [ -z "$ELF_MACHINE" ] && command -v file >/dev/null 2>&1; then
    # 兜底: file -b 输出含 "x86-64" / "ARM aarch64"
    FOUT=$(LC_ALL=C file -b "$BUNDLE/minincm")
    case "$FOUT" in
      *x86-64*)    ELF_MACHINE="Advanced Micro Devices X86-64" ;;
      *aarch64*) ELF_MACHINE="AArch64" ;;
    esac
  fi
  case "$ELF_MACHINE:${APPIMAGE_ARCH:-$DEFAULT_APPIMAGE_ARCH}" in
    "Advanced Micro Devices X86-64:x86_64") ;;   # x64 bundle + x86_64 AppImage
    "AArch64:aarch64") ;;                        # arm64 bundle + aarch64 AppImage
    *)
      echo "ERROR: 架构不匹配: $BUNDLE/minincm 是 ELF Machine=\"$ELF_MACHINE\", 而 APPIMAGE_ARCH=${APPIMAGE_ARCH:-}" >&2
      echo "       目标 AppImage 架构=${APPIMAGE_ARCH:-$DEFAULT_APPIMAGE_ARCH}; 用 BUNDLE=<对应架构的 bundle> 修正, 或不设 APPIMAGE_ARCH 让脚本按主机推断" >&2
      exit 1 ;;
  esac
fi

VER=$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' "$ROOT/ui/pubspec.yaml" | head -1)
ARCH=${APPIMAGE_ARCH:-$DEFAULT_APPIMAGE_ARCH}

TOOL=${APPIMAGETOOL:-}
if [ -z "$TOOL" ]; then
  if command -v appimagetool >/dev/null 2>&1; then
    TOOL=$(command -v appimagetool)
  else
    CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/minincm-packaging
    mkdir -p "$CACHE"
    TOOL="$CACHE/appimagetool-$ARCH.AppImage"
    if [ ! -x "$TOOL" ]; then
      echo "下载 appimagetool 到 $TOOL" >&2
      curl -fsSL -o "$TOOL" \
        "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
      chmod +x "$TOOL"
    fi
  fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/MiniNCM.AppDir"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps" \
         "$APPDIR/usr/share/metainfo"

# Flutter bundle 原样放 usr/bin(二进制靠 /proc/self/exe 找同级 data/ 与 lib/)
cp -a "$BUNDLE"/. "$APPDIR/usr/bin/"
install -m644 "$ROOT/packaging/linux/minincm.png" \
  "$APPDIR/usr/share/icons/hicolor/256x256/apps/minincm.png"
cp "$ROOT/packaging/linux/minincm.png" "$APPDIR/minincm.png"
# AppStream 一起打进 AppDir(与 deb 同一份): 有的桌面集成工具会读它
METAINFO="$APPDIR/usr/share/metainfo/io.github.xiaquwan1001.MiniNCM.metainfo.xml"
install -m644 "$ROOT/packaging/linux/io.github.xiaquwan1001.MiniNCM.metainfo.xml" "$METAINFO"
sed -i "s|<release version=\"[^\"]*\"|<release version=\"$VER\"|" "$METAINFO"

cat > "$APPDIR/minincm.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=轻音 MiniNCM
Name[en]=MiniNCM
Comment=网易云音乐第三方客户端
Exec=minincm %U
Icon=minincm
Terminal=false
Categories=AudioVideo;Audio;Player;
X-AppImage-Version=APPIMAGE_VERSION
DESKTOP
sed -i "s/APPIMAGE_VERSION/$VER/" "$APPDIR/minincm.desktop"
cp "$APPDIR/minincm.desktop" "$APPDIR/usr/share/applications/minincm.desktop"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
# AppImage 入口: 用 AppDir 内的 bundle 启动(不依赖系统装 Flutter 运行时)
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/bin/minincm" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

mkdir -p "$OUT"
OUTFILE="$OUT/MiniNCM-${VER}-linux-${ARCH}.AppImage"
# 无 FUSE 的环境(容器/CI)必须 extract-and-run
ARCH=$ARCH "$TOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUTFILE" >/dev/null 2>&1 \
  || ARCH=$ARCH "$TOOL" --no-appstream "$APPDIR" "$OUTFILE"
chmod +x "$OUTFILE"
ls -lh "$OUTFILE"
echo "appimage: $OUTFILE"
