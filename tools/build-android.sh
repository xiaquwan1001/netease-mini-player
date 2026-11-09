#!/usr/bin/env bash
# 构建 Android APK. 需要 NDK 28.2.13676358(Flutter 3.47 默认)
#   用法: bash tools/build-android.sh            # debug(默认)
#         bash tools/build-android.sh release    # 正式签名 release(需要 ui/android/key.properties)
#
# release 签名来自 ui/android/key.properties(git 忽略, 600):
#   storeFile / storePassword / keyAlias / keyPassword
# 本机密码存在 GNOME keyring, 可用下面两条命令重建该文件(不会把口令写进 git):
#   SP=$(secret-tool lookup app android-release type storepass)
#   KP=$(secret-tool lookup app android-release type keypass)
#   printf 'storeFile=%s/release.keystore\nstorePassword=%s\nkeyAlias=mykey\nkeyPassword=%s\n' "$HOME" "$SP" "$KP" > ui/android/key.properties
# 缺 key.properties 时 Gradle 会回落到 debug 签名(产物不能当发布包, workflow 里有自检)。
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
MODE="${1:-debug}"
case "$MODE" in
  debug|release) ;;
  *) echo "用法: bash tools/build-android.sh [debug|release]" >&2; exit 2 ;;
esac
cd ui
# 只出 arm64 / x86_64 两种 ABI:
#   ① armeabi-v7a(32 位)在当前 rustc + NDK lld 下链接会失败:
#      "ld: error: ...(.debug_aranges): unsupported compression type (44)"
#      —— 是 32 位链接器不认 rustc 生成的 zstd 压缩调试信息, 与我们的代码无关;
#   ② 本项目的目标设备都是 64 位(arm64 手机 / x86_64 模拟器), 32 位机型不在支持范围。
# 需要恢复 32 位: 去掉下面的 --target-platform, 并给 RUSTFLAGS 加 -C debuginfo-compression=none
# (注意 cargokit 不转发 RUSTFLAGS 时需要改 ui/rust_builder 的构建参数)。
if [ "$MODE" = "release" ]; then
  if [ ! -f android/key.properties ]; then
    echo "WARN: 没有 android/key.properties —— release 包会回落到 debug 签名, 不能对外发布" >&2
  fi
  flutter build apk --release --target-platform android-arm64,android-x64
  APK=build/app/outputs/flutter-apk/app-release.apk
else
  flutter build apk --debug --target-platform android-arm64,android-x64
  APK=build/app/outputs/flutter-apk/app-debug.apk
fi
echo "OK -> ui/$APK"
# 签名自检: 打印实际签名证书指纹(便于和 keytool -list 对账)
SIGNER=$(ls "${ANDROID_HOME:-$HOME/android-dev/sdk}"/build-tools/*/apksigner 2>/dev/null | tail -1)
if [ -n "$SIGNER" ]; then "$SIGNER" verify --print-certs "$APK" | grep -E 'Signer #1 certificate (DN|SHA-256)'; fi
