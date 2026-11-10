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
         "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/256x256/apps" \
         "$PKG/usr/share/pixmaps" "$PKG/usr/share/metainfo"

cp -a "$BUNDLE"/. "$PKG/opt/minincm/"
ln -sf /opt/minincm/minincm "$PKG/usr/bin/minincm"
# 图标两处: hicolor 给桌面环境, pixmaps 是部分老工具(以及软件中心的缩略图)的兜底
install -m644 "$ROOT/packaging/linux/minincm.png" \
  "$PKG/usr/share/icons/hicolor/256x256/apps/minincm.png"
install -m644 "$ROOT/packaging/linux/minincm.png" \
  "$PKG/usr/share/pixmaps/minincm.png"

# AppStream: **本地 deb 预览**(文件管理器/软件中心双击查看)显示的中文名与图标来自这里.
# dpkg 的包名必须是全小写 minincm, 改不了; 展示名只能靠 AppStream + desktop 文件.
METAINFO="$PKG/usr/share/metainfo/io.github.xiaquwan1001.MiniNCM.metainfo.xml"
install -m644 "$ROOT/packaging/linux/io.github.xiaquwan1001.MiniNCM.metainfo.xml" "$METAINFO"
# 版本号跟 pubspec 走(源文件里留一个可校验的占位版本, 发布时覆盖成真版本)
sed -i "s|<release version=\"[^\"]*\"|<release version=\"$VER\"|" "$METAINFO"

cat > "$PKG/usr/share/applications/minincm.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=轻音 MiniNCM
Name[en]=MiniNCM
Name[zh_CN]=轻音 MiniNCM
GenericName=Music Player
GenericName[zh_CN]=音乐播放器
Comment=网易云音乐第三方客户端
Comment[en]=A third-party NetEase Cloud Music client
Exec=/opt/minincm/minincm %U
Icon=minincm
Terminal=false
Categories=AudioVideo;Audio;Player;
Keywords=music;netease;ncm;
Keywords[zh_CN]=音乐;网易云;播放器;
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

# 依赖里补 libwebkit 之类是不需要的: 桌面端没有 WebView(登录走官方扫码通道).

mkdir -p "$OUT"
OUTFILE="$OUT/${PKGNAME}_${VER}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$PKG" "$OUTFILE" >/dev/null
ls -lh "$OUTFILE"
echo "deb: $OUTFILE"
