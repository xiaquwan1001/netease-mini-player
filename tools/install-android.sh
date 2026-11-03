#!/usr/bin/env bash
# 装到真机并抓首屏日志.
# vivo 的 adb install 常被系统拒(INSTALL_FAILED_ABORTED), 改走 push + pm install.
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
APK="${1:-ui/build/app/outputs/flutter-apk/app-release.apk}"
[ -f "$APK" ] || { echo "missing $APK (先跑 tools/build-android.sh)"; exit 1; }
adb devices | grep -q device || { echo "no device"; exit 1; }
adb push "$APK" /data/local/tmp/minincm.apk
adb shell pm install -r -t /data/local/tmp/minincm.apk
adb shell am force-stop com.minincm.minincm
adb logcat -c
adb shell am start -n com.minincm.minincm/.MainActivity
sleep 5
adb logcat -d | grep -iE 'flutter|ncm|MediaSession|ExoPlayer|AndroidRuntime|FATAL' | tail -30
