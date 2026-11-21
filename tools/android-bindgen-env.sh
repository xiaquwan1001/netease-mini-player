#!/usr/bin/env bash
# 给「Android 目标的构建期 bindgen」注入 NDK sysroot(rquickjs-sys 没有 *-linux-android 的
# 预生成 bindings, 见 docs/audit/2026-11-21-plugin-android-crosscompile.md §1.3 / §3 推荐 b)。
#
# 用法: tools/android-bindgen-env.sh <命令...>
#   tools/android-bindgen-env.sh cargo check --target aarch64-linux-android -p ncm_ffi
#   tools/android-bindgen-env.sh bash tools/build-android.sh debug   # build-android.sh 已自动套
#
# 为什么要单独一个脚本: bindgen 的 target 专属环境变量名带连字符
# (BINDGEN_EXTRA_CLANG_ARGS_aarch64-linux-android), bash 的 export / declare 只接受合法标识符,
# 只能用 env(1) 以 NAME=VALUE 形式传给子进程。所有 64 位 ABI 的变量一次性都给上,
# 这样一次 gradle/flutter 构建里混合多个 ABI 也不会漏。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
# 复用统一环境(JAVA/ANDROID_HOME/镜像), 不覆盖调用方已设的值.
# CI(GitHub runner)严禁 source: env.sh 会把 JAVA_HOME 指到 ~/android-dev/jdk(不存在),
# gradlew 随即报 "JAVA_HOME is set to an invalid directory"(2026-11-21 v0.34.0 实测).
if [ -f "$ROOT/tools/env.sh" ] && [ -z "${GITHUB_ACTIONS:-}" ] && [ -z "${CI:-}" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/tools/env.sh"
fi

# NDK: 显式 ANDROID_NDK_HOME 优先, 否则取 SDK 下版本最高的一个.
NDK=${ANDROID_NDK_HOME:-}
if [ -z "$NDK" ]; then
  NDK=$(ls -d "${ANDROID_HOME:-$HOME/android-dev/sdk}/ndk/"* 2>/dev/null | sort -V | tail -1 || true)
fi
if [ -z "$NDK" ] || [ ! -d "$NDK/toolchains/llvm/prebuilt" ]; then
  echo "android-bindgen-env: 找不到 NDK(设 ANDROID_NDK_HOME, 或用 tools/env.sh 的 ANDROID_HOME)" >&2
  exit 2
fi
HOST_TAG=$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)
TC="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
if [ ! -d "$TC/sysroot/usr/include" ]; then
  echo "android-bindgen-env: $TC/sysroot 不存在" >&2
  exit 2
fi

# libclang: LIBCLANG_PATH 指向**含 libclang.so 的目录**; 缺了就明确报错(CI 装 clang/libclang-dev).
LIBCLANG=${LIBCLANG_PATH:-}
if [ -z "$LIBCLANG" ]; then
  LIBCLANG=$(ls -d /usr/lib/llvm-*/lib 2>/dev/null | sort -V | tail -1 || true)
fi
if [ -z "$LIBCLANG" ] || [ ! -e "$LIBCLANG/libclang.so" ]; then
  echo "android-bindgen-env: 找不到 libclang(装 clang/libclang-dev, 或设 LIBCLANG_PATH)" >&2
  exit 2
fi

# API level 24 = Flutter 3.47 的 minSdk.
args() { # args <triple> <api>
  echo "--target=$1$2 --sysroot=$TC/sysroot -I$TC/sysroot/usr/include -I$TC/sysroot/usr/include/$1"
}

# C 侧: quickjs 的 .c 由 cc crate 编, cc 的 NDK 自动探测在本机实测不到
# (报 "failed to find tool aarch64-linux-android-clang"), 所以把 CC/AR/RANLIB 显式指到 NDK clang。
# 名字同样带连字符 ⇒ 一样走 env(1)。
export NDK_TC="$TC"
exec env \
  "ANDROID_NDK_HOME=$NDK" \
  "ANDROID_NDK_ROOT=$NDK" \
  "LIBCLANG_PATH=$LIBCLANG" \
  "CC_aarch64-linux-android=$TC/bin/aarch64-linux-android24-clang" \
  "AR_aarch64-linux-android=$TC/bin/llvm-ar" \
  "RANLIB_aarch64-linux-android=$TC/bin/llvm-ranlib" \
  "CC_x86_64-linux-android=$TC/bin/x86_64-linux-android24-clang" \
  "AR_x86_64-linux-android=$TC/bin/llvm-ar" \
  "RANLIB_x86_64-linux-android=$TC/bin/llvm-ranlib" \
  "CC_armv7a-linux-androideabi=$TC/bin/armv7a-linux-androideabi24-clang" \
  "AR_armv7a-linux-androideabi=$TC/bin/llvm-ar" \
  "RANLIB_armv7a-linux-androideabi=$TC/bin/llvm-ranlib" \
  "CC_i686-linux-android=$TC/bin/i686-linux-android24-clang" \
  "AR_i686-linux-android=$TC/bin/llvm-ar" \
  "RANLIB_i686-linux-android=$TC/bin/llvm-ranlib" \
  "BINDGEN_EXTRA_CLANG_ARGS_aarch64-linux-android=$(args aarch64-linux-android 24)" \
  "BINDGEN_EXTRA_CLANG_ARGS_x86_64-linux-android=$(args x86_64-linux-android 24)" \
  "BINDGEN_EXTRA_CLANG_ARGS_armv7-linux-androideabi=$(args armv7-linux-androideabi 24)" \
  "BINDGEN_EXTRA_CLANG_ARGS_armv7a-linux-androideabi=$(args armv7a-linux-androideabi 24)" \
  "BINDGEN_EXTRA_CLANG_ARGS_i686-linux-android=$(args i686-linux-android 24)" \
  "$@"
