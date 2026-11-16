#!/usr/bin/env bash
# CI 门禁与版本解析的**唯一实现**: 本地 tools/ci.sh、GitHub ci.yml / release.yml 都只调这里。
#
# 为什么集中(2026-11-16 平台审计 P-13/P-14): 同一个 `flutter test` 在四处手抄, 口径已经漂了
# —— release.yml 用 --exclude-tags 'network || golden', 比 CI 弱一层(发出去的包没跑 golden
# 视觉回归); token 门与 write-guard 只在本地 ci.sh 里, GitHub CI 根本没跑。集中之后:
# 改一处 = 四边同步, 各处差异只剩"跑哪些子命令"。
#
# 用法:
#   tools/ci-gates.sh list                 # 列出所有子命令
#   tools/ci-gates.sh version              # 从 ui/pubspec.yaml 的 version: X.Y.Z+N 取 X.Y.Z
#   tools/ci-gates.sh check-version <tag>  # tag / pubspec / kAppVersion 三者一致(否则退出 1)
#   tools/ci-gates.sh rust-lint            # cargo fmt --check + clippy -D warnings
#   tools/ci-gates.sh rust-test            # workspace 单测(vendor 联网 smoke 排除)
#   tools/ci-gates.sh dart-format          # dart format --output=none --set-exit-if-changed lib test
#   tools/ci-gates.sh dart-analyze         # dart analyze(不用 flutter analyze, 见下)
#   tools/ci-gates.sh write-guard          # tools/check-write-guard.sh
#   tools/ci-gates.sh tokens               # tools/check-tokens.sh --strict
#   tools/ci-gates.sh row-padding          # tools/check-row-padding.sh --strict(行留白只许用具名口径)
#   tools/ci-gates.sh flutter-test         # flutter test --exclude-tags network(**含 golden**)
#   tools/ci-gates.sh android-unit         # :app:testDebugUnitTest(Android JVM 单测, 不用设备/NDK)
#   tools/ci-gates.sh android-lint         # :app:lintDebug(AGP 自带 lint; 现状 67 error, 不进 verify)
#   tools/ci-gates.sh verify               # 全部离线门(rust-lint/rust-test + dart 四道 + row-padding + flutter-test + android-unit)
#
# 口径约定(改之前先读 .pi/memory/notes-build.md):
#   · 测试标签: 只排除 network(需要真实凭据)。golden **必须跑** —— 它靠 CI 的
#     fonts-noto-cjk + 固定 Flutter 3.47.9 渲染, 是本项目唯一的像素级回归网。
#   · 静态检查用 `dart analyze` 而不是 `flutter analyze`: 本机 flutter analyze 会
#     稳定 SIGSEGV(analysis server 的 Dart VM 在并发标记 GC 崩, 2026-11-09 实测),
#     两者同一套 lint 规则, 真 error 一样阻塞。
#   · 版本号只有 ui/pubspec.yaml 一处事实来源(X.Y.Z = versionName, +N = versionCode),
#     kAppVersion 由 tools/bump-version.sh 同步。
#   · Android 侧静态检查/单测只用 AGP 自带能力(:app:lintDebug + :app:testDebugUnitTest),
#     不引 ktlint/detekt 插件(平台审计明确排除自建静态检查栈)。lint 当前 **67 error**
#     (66 × media3 UnsafeOptInUsageError 缺 @OptIn + 1 × GestureBackNavigation) 必红,
#     修完之前**不进 verify**, 只在 CI 里以 continue-on-error 的独立 step 暴露;
#     不许用 lint-baseline/lint.xml 掩盖(2026-11-16 实测, 细节见 notes-wip.md)。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# 本地直跑时补工具链环境; CI(GitHub runner)严禁 source —— env.sh 会把 JAVA_HOME
# 指到 ~/android-dev/jdk 覆盖 runner 自带的 JDK21, 构建会直接炸。
if [ -z "${GITHUB_ACTIONS:-}" ] && [ -z "${CI:-}" ] && [ -f "$ROOT/tools/env.sh" ]; then
  # shellcheck disable=SC1091
  source "$ROOT/tools/env.sh"
fi

PUBSPEC="$ROOT/ui/pubspec.yaml"
META="$ROOT/ui/lib/src/app_meta.dart"

die() { echo "ERROR: $*" >&2; exit 1; }
run() { echo "+ $*"; "$@"; }

cmd_version() {
  local ver
  ver=$(sed -n 's/^version: \([0-9][0-9.]*\)+.*/\1/p' "$PUBSPEC" | head -1)
  [ -n "$ver" ] || die "读不到 ui/pubspec.yaml 里 X.Y.Z+N 形式的 version"
  printf '%s\n' "$ver"
}

cmd_check_version() {
  local tag=${1:-}
  [ -n "$tag" ] || die "用法: $0 check-version <tag 或版本号>"
  tag=${tag#v}
  local pub meta
  pub=$(cmd_version)
  meta=$(sed -n "s/.*kAppVersion = '\([^']*\)'.*/\1/p" "$META" | head -1)
  [ -n "$meta" ] || die "读不到 ui/lib/src/app_meta.dart 的 kAppVersion"
  echo "tag=$tag pubspec=$pub kAppVersion=$meta"
  if [ "$tag" != "$pub" ] || [ "$pub" != "$meta" ]; then
    die "版本号不一致(tag/pubspec/kAppVersion), 请用 tools/bump-version.sh 后重新打 tag"
  fi
  echo "版本号一致: $pub"
}

cmd_rust_lint() {
  run cargo fmt --manifest-path core/Cargo.toml --all -- --check
  run cargo clippy --manifest-path core/Cargo.toml --workspace --all-targets --locked -- -D warnings
}

cmd_rust_test() {
  # --exclude ncm-api-rs: vendor 的 tests/integration.rs 是匿名真实联网 smoke, 会被上游
  # 风控/公网抖动弹回非 200(与改动无关), 本地另跑(见 tools/ci.sh)。
  run cargo test --manifest-path core/Cargo.toml --workspace --exclude ncm-api-rs --locked
}

cmd_dart_format() {
  ( cd ui && run dart format --output=none --set-exit-if-changed lib test )
}

cmd_dart_analyze() {
  ( cd ui && run dart analyze )
}

cmd_write_guard() {
  echo "+ bash tools/check-write-guard.sh"
  bash "$ROOT/tools/check-write-guard.sh"
}

cmd_tokens() {
  echo "+ bash tools/check-tokens.sh --strict"
  bash "$ROOT/tools/check-tokens.sh" --strict
}

cmd_row_padding() {
  echo "+ bash tools/check-row-padding.sh --strict"
  bash "$ROOT/tools/check-row-padding.sh" --strict
}

cmd_flutter_test() {
  # golden 在内: 缺 CJK 字体会整组 skip(= 没测), 所以跑这条之前必须装 fonts-noto-cjk
  # (CI 见 .github/workflows/*.yml 的 "System deps (fonts-noto-cjk ...)" 步骤)。
  ( cd ui && run flutter test --exclude-tags network "$@" )
}

# ---- Android(JVM 侧: 单测 + lint) ----
# 这两条要一份可用的 Android 工程, 而它依赖两个**不入库**的文件(ui/android/.gitignore 里
# 明确忽略): local.properties(flutter.sdk/sdk.dir) 与 gradlew + gradle-wrapper.jar。
# 新克隆里 ./gradlew 根本不存在, 所以先 bootstrap 再用。
cmd_android_prepare() {
  # gradle 必须跑在带 javac 的 JDK21 上: 本机默认 java 可能只有 JRE(java-25), 会报
  # "does not provide the required capabilities: [JAVA_COMPILER]"。
  if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME:-}/bin/javac" ]; then
    [ -x "$HOME/android-dev/jdk/bin/javac" ] \
      || die "Android 门需要带 javac 的 JDK21: 请设 JAVA_HOME(本地 source tools/env.sh, CI 用 actions/setup-java 21)"
    export JAVA_HOME="$HOME/android-dev/jdk"
  fi
  command -v flutter >/dev/null \
    || die "Android 门需要 flutter 在 PATH 上(--config-only 由它生成 local.properties/gradlew)"
  if [ ! -x ui/android/gradlew ] || [ ! -f ui/android/local.properties ]; then
    # --config-only: 只生成工程文件(local.properties / gradlew / wrapper jar), 不编译产物。
    # 唯一实现交给 flutter —— 手写 local.properties 会把不存在的路径写进去, 拷别处的
    # wrapper 又会漏版本对齐(本机实测 0.3s, 且不会改动 gradle-wrapper.properties)。
    echo "+ (cd ui && flutter build apk --debug --config-only)  # 生成 local.properties + gradlew"
    ( cd ui && flutter build apk --debug --config-only )
  fi
}

cmd_android_unit() {
  cmd_android_prepare
  ( cd ui/android && run ./gradlew :app:testDebugUnitTest --console=plain )
}

cmd_android_lint() {
  cmd_android_prepare
  ( cd ui/android && run ./gradlew :app:lintDebug --console=plain )
}

cmd_verify() {
  cmd_rust_lint
  cmd_rust_test
  cmd_dart_format
  cmd_dart_analyze
  cmd_write_guard
  cmd_tokens
  cmd_row_padding
  cmd_flutter_test
  cmd_android_unit
  echo "ALL GATES OK"
}

sub=${1:-}
[ $# -gt 0 ] && shift
case "$sub" in
  version)       cmd_version ;;
  check-version) cmd_check_version "$@" ;;
  rust-lint)     cmd_rust_lint ;;
  rust-test)     cmd_rust_test ;;
  dart-format)   cmd_dart_format ;;
  dart-analyze)  cmd_dart_analyze ;;
  write-guard)   cmd_write_guard ;;
  tokens)        cmd_tokens ;;
  row-padding)   cmd_row_padding ;;
  flutter-test)  cmd_flutter_test "$@" ;;
  android-unit)  cmd_android_unit ;;
  android-lint)  cmd_android_lint ;;
  verify)        cmd_verify ;;
  list)
    sed -n 's/^#   tools\/ci-gates.sh \(.*\)$/  \1/p' "$0"
    ;;
  *)
    echo "用法: $0 <子命令>; 子命令见 $0 list" >&2
    exit 2
    ;;
esac
