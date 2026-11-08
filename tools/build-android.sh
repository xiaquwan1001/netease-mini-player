#!/usr/bin/env bash
# 构建 Android debug APK. 需要 NDK 28.2.13676358(Flutter 3.47 默认)
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
cd ui
# 只出 arm64 / x86_64 两种 ABI:
#   ① armeabi-v7a(32 位)在当前 rustc + NDK lld 下链接会失败:
#      "ld: error: ...(.debug_aranges): unsupported compression type (44)"
#      —— 是 32 位链接器不认 rustc 生成的 zstd 压缩调试信息, 与我们的代码无关;
#   ② 本项目的目标设备都是 64 位(arm64 手机 / x86_64 模拟器), 32 位机型不在支持范围。
# 需要恢复 32 位: 去掉下面的 --target-platform, 并给 RUSTFLAGS 加 -C debuginfo-compression=none
# (注意 cargokit 不转发 RUSTFLAGS 时需要改 ui/rust_builder 的构建参数)。
flutter build apk --debug --target-platform android-arm64,android-x64
echo "OK -> ui/build/app/outputs/flutter-apk/app-debug.apk"
