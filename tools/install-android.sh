#!/usr/bin/env bash
# 装到真机并抓首屏日志.
# vivo 的安装确认无法绕过: 每次都要在手机上点「安装/继续安装」, 脚本会阻塞等待.
# 未点确认(或屏幕锁着)时报 INSTALL_FAILED_ABORTED: User rejected permissions, 不是脚本问题.
# 走 push + pm install 只是避开 streamed install 的额外弹窗, 二次确认仍然存在.
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
echo "==> 马上会在手机上弹出安装确认, 请点「安装/继续安装」(脚本会一直等)"
adb -s "$SERIAL" push "$APK" /data/local/tmp/minincm.apk
adb -s "$SERIAL" shell pm install -r -t /data/local/tmp/minincm.apk
adb -s "$SERIAL" shell am force-stop com.minincm.minincm
adb -s "$SERIAL" logcat -c
adb -s "$SERIAL" shell am start -n com.minincm.minincm/.MainActivity
sleep 5
adb -s "$SERIAL" logcat -d | grep -iE 'flutter|ncm|MediaSession|ExoPlayer|AndroidRuntime|FATAL' | tail -30
