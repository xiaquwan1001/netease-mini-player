#!/usr/bin/env bash
# 构建 Android debug APK. 需要 NDK 28.2.13676358(Flutter 3.47 默认)
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
cd ui
flutter build apk --debug
echo "OK -> ui/build/app/outputs/flutter-apk/app-debug.apk"
