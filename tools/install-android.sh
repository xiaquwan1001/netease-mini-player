#!/usr/bin/env bash
# 装到真机并抓首屏日志.
# vivo 的 adb install 常被系统拒(INSTALL_FAILED_ABORTED), 改走 push + pm install;
# 手机必须亮屏解锁, 否则 pm install 也会被"用户拒绝".
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh

APK="${1:-ui/build/app/outputs/flutter-apk/app-release.apk}"
[ -f "$APK" ] || { echo "missing $APK (先跑 tools/build-android.sh)"; exit 1; }

SERIAL="${ANDROID_SERIAL:-}"
if [ -z "$SERIAL" ]; then
  count=$(adb devices | awk 'NR>1 && $2=="device"' | wc -l)
  if [ "$count" -eq 0 ]; then echo "no device"; exit 1; fi
  if [ "$count" -gt 1 ]; then echo "multiple devices; set ANDROID_SERIAL=..."; adb devices -l; exit 1; fi
  SERIAL=$(adb devices | awk 'NR>1 && $2=="device"{print $1; exit}')
fi

echo "device: $SERIAL"
adb -s "$SERIAL" push "$APK" /data/local/tmp/minincm.apk
adb -s "$SERIAL" shell pm install -r -t /data/local/tmp/minincm.apk
adb -s "$SERIAL" shell am force-stop com.minincm.minincm
adb -s "$SERIAL" logcat -c
adb -s "$SERIAL" shell am start -n com.minincm.minincm/.MainActivity
sleep 5
adb -s "$SERIAL" logcat -d | grep -iE 'flutter|ncm|MediaSession|ExoPlayer|AndroidRuntime|FATAL' | tail -30
