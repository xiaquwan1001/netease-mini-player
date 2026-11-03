#!/usr/bin/env bash
# 统一开发环境变量. 用法: source tools/env.sh
# 全部用户级: JDK21 / Gradle / Android SDK / Flutter 都在 ~/android-dev
export ANDROID_DEV_ROOT="${ANDROID_DEV_ROOT:-$HOME/android-dev}"
export JAVA_HOME="$ANDROID_DEV_ROOT/jdk"
export ANDROID_HOME="$ANDROID_DEV_ROOT/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export FLUTTER_ROOT="$ANDROID_DEV_ROOT/flutter"
export PATH="$FLUTTER_ROOT/bin:$JAVA_HOME/bin:$HOME/.cargo/bin:$ANDROID_HOME/platform-tools:$PATH"
# 国内镜像(Flutter 引擎/pub)
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
