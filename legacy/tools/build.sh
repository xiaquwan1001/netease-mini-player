#!/usr/bin/env bash
# 构建 debug APK: bash tools/build.sh
set -euo pipefail
unset https_proxy http_proxy HTTPS_PROXY HTTP_PROXY ALL_PROXY all_proxy
ROOT="${ANDROID_DEV_ROOT:-$HOME/android-dev}"
export JAVA_HOME="$ROOT/jdk"
export ANDROID_HOME="$ROOT/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ROOT/gradle-8.9/bin:$PATH"
cd "$(dirname "$0")/../android"
gradle assembleDebug --no-daemon --console=plain "$@"
APK=app/build/outputs/apk/debug/app-debug.apk
ls -l "$APK"
echo "install: adb install -r $PWD/$APK"
