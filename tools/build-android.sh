#!/usr/bin/env bash
# 构建 Android APK. 需要 NDK 28.2.13676358(Flutter 3.47 默认)
#   用法: bash tools/build-android.sh            # debug(默认, 按 ABI 分包)
#         bash tools/build-android.sh release    # 正式签名 release(需要 ui/android/key.properties)
#
# debug 用 --split-per-abi 产两个小包(不再出 170MB 的 universal 包):
#   app-x86_64-debug.apk    模拟器(a34)用, ≈88MB
#   app-arm64-v8a-debug.apk 真机用, ≈99MB
# 装到模拟器: adb -s emulator-5554 install -r ui/build/app/outputs/flutter-apk/app-x86_64-debug.apk
#
# release 签名来自 ui/android/key.properties(git 忽略, 600):
#   storeFile / storePassword / keyAlias / keyPassword
# 本机密码存在 GNOME keyring, 可用下面两条命令重建该文件(不会把口令写进 git):
#   SP=$(secret-tool lookup app android-release type storepass)
#   KP=$(secret-tool lookup app android-release type keypass)
#   printf 'storeFile=%s/release.keystore\nstorePassword=%s\nkeyAlias=mykey\nkeyPassword=%s\n' "$HOME" "$SP" "$KP" > ui/android/key.properties
# 缺 key.properties 时 Gradle 会回落到 debug 签名(产物不能当发布包, workflow 里有自检)。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
source tools/env.sh

# 插件宿主在 Android 用**构建期 bindgen**(rquickjs-sys 没有 *-linux-android 的预生成
# bindings)⇒ 必须有 NDK sysroot + libclang 那套环境变量。变量名带连字符, bash 不能 export,
# 所以先经 tools/android-bindgen-env.sh(用 env(1))重跑自己; 该脚本失败时这里直接退出。
if [ -z "${NCM_ANDROID_BINDGEN_ENV:-}" ]; then
  export NCM_ANDROID_BINDGEN_ENV=1
  exec "$ROOT/tools/android-bindgen-env.sh" bash "$0" "$@"
fi

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
# release 也走 --split-per-abi: 不加时产的是**双 ABI 合体包**(实测 57.5MB),
# 而 CI/Release 发的是 arm64-only(~33MB) —— 本地"release 验收"验的东西和发布件不是同一个
# (2026-11-28 构建链审计 #3)。拆分后按 ABI 出两个包, 与 Release 资产一一对得上。
if [ "$MODE" = "release" ]; then
  if [ ! -f android/key.properties ]; then
    echo "WARN: 没有 android/key.properties —— release 包会回落到 debug 签名, 不能对外发布" >&2
  fi
  flutter build apk --release --split-per-abi --target-platform android-arm64,android-x64
  APK=build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
else
  flutter build apk --debug --split-per-abi --target-platform android-arm64,android-x64
  echo "OK -> ui/build/app/outputs/flutter-apk/app-x86_64-debug.apk    (模拟器 x86_64)"
  echo "OK -> ui/build/app/outputs/flutter-apk/app-arm64-v8a-debug.apk  (真机 arm64)"
  APK=build/app/outputs/flutter-apk/app-x86_64-debug.apk
fi
echo "OK -> ui/$APK"
# ABI 自检(2026-11-28 构建链审计): 产物只允许 64 位 ABI。
# 这条门的意义是防"又打出一份含 v7a 的 216MB 合体包"——那种包只能装到 32 位机型上崩。
if command -v unzip >/dev/null 2>&1; then
  ABIS=$(unzip -Z1 "$APK" 2>/dev/null | sed -n 's#^lib/\([^/]*\)/.*#\1#p' | sort -u | tr '\n' ' ')
  echo "ABI -> ${ABIS:-<none>}"
  case " $ABIS " in
    *" armeabi-v7a "*|*" x86 "*)
      echo "FAIL: APK 里混进了 32 位 ABI(${ABIS})——检查 --target-platform / ndk.abiFilters" >&2
      exit 1
      ;;
  esac
fi
# 签名自检: 打印实际签名证书指纹(便于和 keytool -list 对账)
SIGNER=$(ls "${ANDROID_HOME:-$HOME/android-dev/sdk}"/build-tools/*/apksigner 2>/dev/null | tail -1)
if [ -n "$SIGNER" ]; then "$SIGNER" verify --print-certs "$APK" | grep -E 'Signer #1 certificate (DN|SHA-256)'; fi
