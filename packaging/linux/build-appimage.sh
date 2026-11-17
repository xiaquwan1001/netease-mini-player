#!/usr/bin/env bash
# 用 `flutter build linux --release` 的 bundle 打 AppImage.
# 用法: bash packaging/linux/build-appimage.sh [输出目录, 默认 dist]
#
# 需要 appimagetool: 优先 $APPIMAGETOOL, 其次 PATH, 最后自动下载(P-17: 固定 tag + sha256 校验)
# 到 ~/.cache/minincm-packaging. 显式指定的 $APPIMAGETOOL / PATH 里的版本视为用户自选, 不校验.
# CI/无 FUSE 环境自动用 --appimage-extract-and-run(等效 APPIMAGE_EXTRACT_AND_RUN=1).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:-$ROOT/dist}

# P-18 后半: 与 deb / ui/linux/CMakeLists.txt 共用同一个 application-id。
# AppDir 根部的 .desktop 文件名 + 里面的 StartupWMClass(= WM_CLASS = APPLICATION_ID)
# 必须与 AppStream id 完全一致, 否则任务栏不归组、软件中心关联不到元数据。
APPID=io.github.xiaquwan1001.MiniNCM
CMAKE_APPID=$(sed -n 's/^set(APPLICATION_ID "\(.*\)")$/\1/p' "$ROOT/ui/linux/CMakeLists.txt")
[ "$CMAKE_APPID" = "$APPID" ] || {
  echo "ERROR: APPID 与 ui/linux/CMakeLists.txt 的 APPLICATION_ID 不一致(CMake='$CMAKE_APPID', 本脚本='$APPID')" >&2
  exit 1; }

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

# 版本号解析唯一实现: tools/ci-gates.sh
VER=$(bash "$ROOT/tools/ci-gates.sh" version)
ARCH=${APPIMAGE_ARCH:-$DEFAULT_APPIMAGE_ARCH}

# appimagetool 工具链 pin(P-17): 只从固定 release tag 下载并校验 sha256, 不追可变的
# releases/download/continuous. 升级 tag 时先取新 sha256 再改下面两行常量:
#   gh release view <tag> --repo AppImage/appimagetool --json assets \
#     | python3 -c 'import json,sys;[print(a["name"],a["digest"]) for a in json.load(sys.stdin)["assets"]]'
# (或下载后 sha256sum appimagetool-<arch>.AppImage 与新 digest 手工确认一致)
APPIMAGETOOL_TAG=1.9.1
case "$ARCH" in
  x86_64)  APPIMAGETOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 ;;
  aarch64) APPIMAGETOOL_SHA256=f0837e7448a0c1e4e650a93bb3e85802546e60654ef287576f46c71c126a9158 ;;
  *) echo "ERROR: 没有 appimagetool 的 sha256 pin: ARCH=$ARCH" >&2; exit 1 ;;
esac

# sha256 校验: 不一致就退出, 绝不 chmod +x 内容未知的二进制.
verify_appimagetool_sha256() {
  local file=$1 actual sums
  sums=$(mktemp)
  printf '%s  %s\n' "$APPIMAGETOOL_SHA256" "$file" > "$sums"
  if command -v sha256sum >/dev/null 2>&1; then
    if sha256sum -c "$sums" >/dev/null 2>&1; then rm -f "$sums"; return 0; fi
    actual=$(sha256sum "$file" | cut -d' ' -f1)
  elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
  else
    rm -f "$sums"
    echo "ERROR: 系统没有 sha256sum/shasum, 无法校验 appimagetool($file)" >&2
    return 1
  fi
  rm -f "$sums"
  if [ "$actual" = "$APPIMAGETOOL_SHA256" ]; then return 0; fi
  echo "ERROR: appimagetool sha256 校验失败: $file" >&2
  echo "       期望 sha256: $APPIMAGETOOL_SHA256 (tag $APPIMAGETOOL_TAG, appimagetool-$ARCH.AppImage)" >&2
  echo "       实际 sha256: ${actual:-<计算失败>}" >&2
  return 1
}

TOOL=${APPIMAGETOOL:-}
if [ -z "$TOOL" ]; then
  if command -v appimagetool >/dev/null 2>&1; then
    # PATH 里的版本由用户/发行版提供, 不校验(显式选择优先于供应链 pin)
    TOOL=$(command -v appimagetool)
  else
    CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/minincm-packaging
    mkdir -p "$CACHE"
    # 缓存名带 tag: 换 tag 不会命中旧二进制
    TOOL="$CACHE/appimagetool-$ARCH-$APPIMAGETOOL_TAG.AppImage"
    if [ -e "$TOOL" ] && ! verify_appimagetool_sha256 "$TOOL"; then
      echo "缓存文件校验失败, 删除后重新下载: $TOOL" >&2
      rm -f "$TOOL"
    fi
    if [ ! -x "$TOOL" ]; then
      echo "下载 appimagetool $APPIMAGETOOL_TAG ($ARCH) 到 $TOOL" >&2
      DL_TMP="$TOOL.part"
      rm -f "$DL_TMP"
      curl -fsSL --retry 3 --connect-timeout 20 -o "$DL_TMP" \
        "https://github.com/AppImage/appimagetool/releases/download/$APPIMAGETOOL_TAG/appimagetool-$ARCH.AppImage"
      verify_appimagetool_sha256 "$DL_TMP" || { rm -f "$DL_TMP"; exit 1; }
      chmod +x "$DL_TMP"
      mv -f "$DL_TMP" "$TOOL"
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
METAINFO="$APPDIR/usr/share/metainfo/$APPID.metainfo.xml"
install -m644 "$ROOT/packaging/linux/$APPID.metainfo.xml" "$METAINFO"
sed -i "s|<release version=\"[^\"]*\"|<release version=\"$VER\"|" "$METAINFO"
# 断言(P-19): sed 静默 no-op 会让包带着占位版本出厂而流水线全绿 → 硬失败
grep -q "version=\"$VER\"" "$METAINFO" || {
  echo "ERROR: metainfo 版本覆盖失败($METAINFO 里没有 version=\"$VER\")" >&2; exit 1; }

cat > "$APPDIR/${APPID}.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=轻音 MiniNCM
Name[en]=MiniNCM
Name[zh_CN]=轻音 MiniNCM
GenericName=Music Player
GenericName[zh_CN]=音乐播放器
Comment=网易云音乐第三方客户端
Comment[en]=A third-party NetEase Cloud Music client
Exec=minincm %U
Icon=minincm
Terminal=false
Categories=AudioVideo;Audio;Player;
Keywords=music;netease;ncm;
StartupWMClass=APPIMAGE_APPID
X-AppImage-Version=APPIMAGE_VERSION
DESKTOP
sed -i "s/APPIMAGE_VERSION/$VER/; s/APPIMAGE_APPID/$APPID/" "$APPDIR/${APPID}.desktop"
cp "$APPDIR/${APPID}.desktop" "$APPDIR/usr/share/applications/${APPID}.desktop"

cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
# AppImage 入口: 用 AppDir 内的 bundle 启动(不依赖系统装 Flutter 运行时)
HERE=$(dirname "$(readlink -f "$0")")
exec "$HERE/usr/bin/minincm" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

mkdir -p "$OUT"
OUTFILE="$OUT/MiniNCM-${VER}-linux-${ARCH}.AppImage"
# 无 FUSE 的环境(容器/CI)必须 extract-and-run.
# 失败不掩埋 stderr(P-17): 两次尝试的完整输出都写进 $TOOL_LOG, 全部失败时原样打印出来.
TOOL_LOG="$WORK/appimagetool.log"
if ARCH=$ARCH "$TOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$OUTFILE" >"$TOOL_LOG" 2>&1; then
  :
else
  RC=$?
  echo "提示: --appimage-extract-and-run 失败(rc=$RC), 回退直接执行(该路径需要 FUSE)" >&2
  if ! ARCH=$ARCH "$TOOL" --no-appstream "$APPDIR" "$OUTFILE" >>"$TOOL_LOG" 2>&1; then
    echo "ERROR: appimagetool 两次尝试都失败, 完整输出($TOOL_LOG):" >&2
    sed 's/^/  | /' "$TOOL_LOG" >&2
    exit 1
  fi
fi
chmod +x "$OUTFILE"
ls -lh "$OUTFILE"
echo "appimage: $OUTFILE"
