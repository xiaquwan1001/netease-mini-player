#!/usr/bin/env bash
# 用 `flutter build linux --release` 的 bundle 打 .deb(纯 dpkg-deb, 无额外工具依赖).
# 用法: bash packaging/linux/build-deb.sh [输出目录, 默认 dist]
#
# 布局: /opt/minincm/<bundle> + /usr/bin/minincm 软链 + desktop/icon + DEBIAN/control.
# 之所以放 /opt 而不是 /usr/lib: Flutter bundle 里二进制要能找到同级的 data/ 与 lib/,
# 保持 bundle 目录结构不动最稳(改动布局会让 Flutter 找不到 assets).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/dist}
BUNDLE="$ROOT/ui/build/linux/x64/release/bundle"
[ -x "$BUNDLE/minincm" ] || { echo "缺少 $BUNDLE/minincm, 先跑 flutter build linux --release" >&2; exit 1; }

VER=$(sed -n 's/^version: \([0-9.]*\)+.*/\1/p' "$ROOT/ui/pubspec.yaml" | head -1)
[ -n "$VER" ] || { echo "读不到 ui/pubspec.yaml 的 version" >&2; exit 1; }
ARCH=${ARCH:-amd64}
PKGNAME=minincm
MAINTAINER=${MAINTAINER:-"MiniNCM <noreply@localhost>"}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/${PKGNAME}_${VER}_${ARCH}"
mkdir -p "$PKG/DEBIAN" "$PKG/opt/minincm" "$PKG/usr/bin" \
         "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/256x256/apps"

cp -a "$BUNDLE"/. "$PKG/opt/minincm/"
ln -sf /opt/minincm/minincm "$PKG/usr/bin/minincm"
install -m644 "$ROOT/packaging/linux/minincm.png" \
  "$PKG/usr/share/icons/hicolor/256x256/apps/minincm.png"

cat > "$PKG/usr/share/applications/minincm.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=轻音 MiniNCM
Name[en]=MiniNCM
GenericName=Music Player
Comment=网易云音乐第三方客户端
Exec=/opt/minincm/minincm %U
Icon=minincm
Terminal=false
Categories=AudioVideo;Audio;Player;
Keywords=music;netease;ncm;
StartupWMClass=minincm
DESKTOP

# 依赖: Flutter Linux 桌面壳 + 音频(ALSA) + 压缩解码
INSTALLED_KB=$(du -sk --apparent-size "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: ${PKGNAME}
Version: ${VER}
Section: sound
Priority: optional
Architecture: ${ARCH}
Depends: libgtk-3-0, libasound2, liblzma5, libstdc++6, libc6 (>= 2.31)
Recommends: libnotify4
Installed-Size: ${INSTALLED_KB}
Maintainer: ${MAINTAINER}
Homepage: https://github.com/xiaquwan1001/netease-mini-player
Description: 轻音 MiniNCM - 网易云音乐第三方客户端
 Rust core + Flutter UI 的网易云音乐客户端(桌面端).
 播放引擎为纯 Rust(rodio/CPAL + symphonia), 不依赖 mpv/MPRIS.
CONTROL

mkdir -p "$OUT"
OUTFILE="$OUT/${PKGNAME}_${VER}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$OUTFILE" >/dev/null
ls -lh "$OUTFILE"
echo "deb: $OUTFILE"
