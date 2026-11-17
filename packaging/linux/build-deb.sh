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

# P-18 后半: .desktop 文件名与 StartupWMClass 都跟 application-id / AppStream id 统一。
# 包名(minincm)受 dpkg 全小写约束改不了, 但"桌面归属"由这三个 id 决定, 必须完全一致:
#   ui/linux/CMakeLists.txt 的 APPLICATION_ID(= WM_CLASS, 见 runner 里的 g_set_prgname)
#   usr/share/applications/<id>.desktop 的文件名
#   usr/share/metainfo/<id>.metainfo.xml 里的 <id> 与 <launchable>
APPID=io.github.xiaquwan1001.MiniNCM
CMAKE_APPID=$(sed -n 's/^set(APPLICATION_ID "\(.*\)")$/\1/p' "$ROOT/ui/linux/CMakeLists.txt")
[ "$CMAKE_APPID" = "$APPID" ] || {
  echo "ERROR: APPID 与 ui/linux/CMakeLists.txt 的 APPLICATION_ID 不一致(CMake='$CMAKE_APPID', 本脚本='$APPID')" >&2
  exit 1; }

# 架构: Flutter 的构建目录按主机架构命名(x64 / arm64), deb 的架构名是 amd64 / arm64。
# 默认按本机推断; 需要复用别的架构产物时用 ARCH=<deb 架构> BUNDLE=<bundle 目录> 覆盖
# (arm64 包在 ubuntu-24.04-arm runner 上原生构建 —— Flutter 桌面不支持交叉编译)。
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64)  FLUTTER_ARCH=x64;   DEB_ARCH=amd64 ;;
  aarch64|arm64) FLUTTER_ARCH=arm64; DEB_ARCH=arm64 ;;
  *) echo "不支持的架构: $HOST_ARCH" >&2; exit 1 ;;
esac
BUNDLE=${BUNDLE:-$ROOT/ui/build/linux/$FLUTTER_ARCH/release/bundle}
[ -x "$BUNDLE/minincm" ] || { echo "缺少 $BUNDLE/minincm, 先跑 flutter build linux --release" >&2; exit 1; }

# Ubuntu 22.04(jammy) 只有 GLib 2.72: runner 若引用了 g_once_init_*_pointer(Since 2.80)
# 则装上就是 "symbol lookup error"(issue #2)。CMake 里已把 GLib 基线钉到 2.72,
# 这里在打包含前再验一遍, 免得抱着坏 bundle 出包。
if command -v nm >/dev/null 2>&1; then
  BAD=$(nm -D --undefined-only "$BUNDLE/minincm" | grep -oE 'g_once_init_(enter|leave)_pointer' | sort -u || true)
  [ -z "$BAD" ] || { echo "ERROR: minincm 引用了 GLib 2.80 符号($BAD), Ubuntu 22.04 起不来" >&2; exit 1; }
fi

# 版本号解析唯一实现: tools/ci-gates.sh(从 ui/pubspec.yaml 的 version: X.Y.Z+N 取 X.Y.Z)
VER=$(bash "$ROOT/tools/ci-gates.sh" version)
ARCH=${ARCH:-$DEB_ARCH}
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
METAINFO="$PKG/usr/share/metainfo/$APPID.metainfo.xml"
install -m644 "$ROOT/packaging/linux/$APPID.metainfo.xml" "$METAINFO"
# 版本号跟 pubspec 走(源文件里留一个可校验的占位版本, 发布时覆盖成真版本)
sed -i "s|<release version=\"[^\"]*\"|<release version=\"$VER\"|" "$METAINFO"
# 断言(P-19): sed 一旦没命中(属性顺序/引号变了)会静默 no-op, 出厂包就带着占位版本
# 0.3.2 进软件中心而流水线全绿, 所以这里必须硬失败。
grep -q "version=\"$VER\"" "$METAINFO" || {
  echo "ERROR: metainfo 版本覆盖失败($METAINFO 里没有 version=\"$VER\")" >&2; exit 1; }

# 文件名必须是 <id>.desktop(P-18 后半): AppStream 的 <launchable type="desktop-id"> 与
# 软件中心/任务栏都按这个匹配; StartupWMClass 同理(值 = WM_CLASS = APPLICATION_ID)。
cat > "$PKG/usr/share/applications/${APPID}.desktop" <<DESKTOP
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
StartupWMClass=${APPID}
DESKTOP

# 依赖: Flutter Linux 桌面壳 + 音频(ALSA) + 压缩解码 + D-Bus(secret-service 凭据后端, keyring)
INSTALLED_KB=$(du -sk --apparent-size "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<CONTROL
Package: ${PKGNAME}
Version: ${VER}
Section: sound
Priority: optional
Architecture: ${ARCH}
Depends: libgtk-3-0, libasound2, libdbus-1-3, libstdc++6, libc6 (>= 2.31)
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
