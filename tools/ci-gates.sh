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
#   tools/ci-gates.sh flutter-test         # flutter test --exclude-tags network(**含 golden**)
#   tools/ci-gates.sh verify               # 全部离线门(rust-lint/rust-test + dart 四道 + flutter-test)
#
# 口径约定(改之前先读 .pi/memory/notes-build.md):
#   · 测试标签: 只排除 network(需要真实凭据)。golden **必须跑** —— 它靠 CI 的
#     fonts-noto-cjk + 固定 Flutter 3.47.9 渲染, 是本项目唯一的像素级回归网。
#   · 静态检查用 `dart analyze` 而不是 `flutter analyze`: 本机 flutter analyze 会
#     稳定 SIGSEGV(analysis server 的 Dart VM 在并发标记 GC 崩, 2026-11-09 实测),
#     两者同一套 lint 规则, 真 error 一样阻塞。
#   · 版本号只有 ui/pubspec.yaml 一处事实来源(X.Y.Z = versionName, +N = versionCode),
#     kAppVersion 由 tools/bump-version.sh 同步。
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

cmd_flutter_test() {
  # golden 在内: 缺 CJK 字体会整组 skip(= 没测), 所以跑这条之前必须装 fonts-noto-cjk
  # (CI 见 .github/workflows/*.yml 的 "System deps (fonts-noto-cjk ...)" 步骤)。
  ( cd ui && run flutter test --exclude-tags network "$@" )
}

cmd_verify() {
  cmd_rust_lint
  cmd_rust_test
  cmd_dart_format
  cmd_dart_analyze
  cmd_write_guard
  cmd_tokens
  cmd_flutter_test
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
  flutter-test)  cmd_flutter_test "$@" ;;
  verify)        cmd_verify ;;
  list)
    sed -n 's/^#   tools\/ci-gates.sh \(.*\)$/  \1/p' "$0"
    ;;
  *)
    echo "用法: $0 <子命令>; 子命令见 $0 list" >&2
    exit 2
    ;;
esac
