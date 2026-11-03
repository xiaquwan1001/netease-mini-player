#!/usr/bin/env bash
# 用户级安装安卓构建工具链(无需 sudo, 全部装在 ~/android-dev)
# 产物: ~/android-dev/{jdk, gradle-8.9, sdk}
# 用法: bash tools/setup-android-env.sh
set -euo pipefail
unset https_proxy http_proxy HTTPS_PROXY HTTP_PROXY ALL_PROXY all_proxy
ROOT="${ANDROID_DEV_ROOT:-$HOME/android-dev}"
mkdir -p "$ROOT"; cd "$ROOT"
C="curl -L --noproxy '*' -sS --retry 2 --max-time 900"

# 1) JDK: 必须 >= 17.0.9/21。17.0.2 在 cgroup v2 + 本机内核下会触发
#    "Cannot invoke CgroupInfo.getMountPoint() because anyController is null" (validateSigningDebug 崩)。
if [ ! -x "$ROOT/jdk/bin/java" ] || ! "$ROOT/jdk/bin/java" -version 2>&1 | grep -qE '"(21|17\.0\.(9|[1-9][0-9]))'; then
  echo "[1/4] Temurin JDK 21 (USTC mirror)"
  $C -o jdk21.tar.gz "https://mirrors.ustc.edu.cn/adoptium/releases/temurin21-binaries/LatestRelease/OpenJDK21U-jdk_x64_linux_hotspot_21.0.9_10.tar.gz"
  rm -rf jdk && mkdir jdk && tar xzf jdk21.tar.gz -C jdk --strip-components=1 && rm -f jdk21.tar.gz
fi

# 2) Gradle 8.9 (腾讯云镜像, 官方 services.gradle.org 在本机只有 ~1KB/s)
if [ ! -x "$ROOT/gradle-8.9/bin/gradle" ]; then
  echo "[2/4] Gradle 8.9"
  $C -o gradle.zip "https://mirrors.cloud.tencent.com/gradle/gradle-8.9-bin.zip"
  unzip -q -o gradle.zip && rm -f gradle.zip
fi

export JAVA_HOME="$ROOT/jdk"
export ANDROID_HOME="$ROOT/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ROOT/gradle-8.9/bin:$PATH"

# 3) cmdline-tools
if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "[3/4] Android cmdline-tools"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  $C -o clt.zip "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
  rm -rf clt && mkdir clt && unzip -q clt.zip -d clt && rm -f clt.zip
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv clt/cmdline-tools "$ANDROID_HOME/cmdline-tools/latest" && rmdir clt
fi

# 4) platform 34 + build-tools (compileSdk/targetSdk=34)
echo "[4/4] platforms;android-34 build-tools;34.0.0 platform-tools"
yes | sdkmanager --sdk_root="$ANDROID_HOME" --licenses >/dev/null 2>&1 || true
sdkmanager --sdk_root="$ANDROID_HOME" "platform-tools" "platforms;android-34" "build-tools;34.0.0" >/dev/null

echo "OK: java=$("$JAVA_HOME/bin/java" -version 2>&1 | head -1)"
echo "OK: gradle=$("$ROOT/gradle-8.9/bin/gradle" --version | grep '^Gradle')"
echo "OK: sdk=$ANDROID_HOME (platforms: $(ls "$ANDROID_HOME/platforms"))"
