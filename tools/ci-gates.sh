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
#   tools/ci-gates.sh rust-lint            # cargo fmt --check + clippy -D warnings(workspace 全量, 含 ncm-plugin)
#   tools/ci-gates.sh rust-test            # workspace 单测(只排除 vendor 的联网 smoke)
#   tools/ci-gates.sh dart-format          # dart format --output=none --set-exit-if-changed lib test
#   tools/ci-gates.sh dart-analyze         # dart analyze(不用 flutter analyze, 见下)
#   tools/ci-gates.sh write-guard          # tools/check-write-guard.sh
#   tools/ci-gates.sh lock-poison          # tools/check-lock-poison.sh(生产代码里禁 lock().unwrap())
#   tools/ci-gates.sh tokens               # tools/check-tokens.sh --strict
#   tools/ci-gates.sh row-padding          # tools/check-row-padding.sh --strict(行留白只许用具名口径)
#   tools/ci-gates.sh sheet-entry          # tools/check-sheet-entry.sh(浮层只许经 app_sheet.dart 入口)
#   tools/ci-gates.sh global-slots         # tools/check-global-slots.sh(全局槽位只许声明方/home_wiring 写)
#   tools/ci-gates.sh docs                 # tools/check-docs.sh(docs/** 与根 *.md 的相对链接死链 + docs 根索引覆盖)
#   tools/ci-gates.sh flutter-test         # flutter test --exclude-tags network(**含 golden**)
#   tools/ci-gates.sh android-unit         # :app:testDebugUnitTest(Android JVM 单测, 不用设备/NDK)
#   tools/ci-gates.sh android-instrumented # 设备级 androidTest(需在线**模拟器**; 没设备就 SKIP 退 0)
#   tools/ci-gates.sh android-test-emu     # 【可选】同上但**钉本项目的 emulator-5554**(a34); 不在线就 SKIP 退 0,
#                                          # 不进 verify, 必须显式调用(2026-11-19 实测 6 例/0 失败/1 assume-skip/15.9s)
#   tools/ci-gates.sh android-lint         # :app:lintDebug(AGP 自带 lint; 已 0 error, 在 verify 里)
#   tools/ci-gates.sh desktop-smoke        # 桌面无头冒烟(xvfb+dbus; 没 bundle / 缺工具就 SKIP 退 0)
#                                          # 含**交互级断言**(X11 注入焦点/按键/点击/改尺寸后断言存活+窗口属性不变,
#                                          # 见 tools/smoke-desktop-headless 头注释), 本机约 **60s**
#                                          # (vs 只有启动/单实例/信号时的 45s; 交互段 +15s)
#   tools/ci-gates.sh verify               # 全部离线门(rust-lint/rust-test + dart 四道 + 六道 checker
#                                          # + flutter-test + android-unit + android-lint);
#                                          # 带 NCM_INSTRUMENTED=1 时额外跑 android-instrumented(有模拟器才真跑)
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
#     不引 ktlint/detekt 插件(平台审计明确排除自建静态检查栈)。lint **已 0 error**
#     (2026-11-18: 66 × media3 UnsafeOptInUsageError 收口到类级 @OptIn/@UnstableApi,
#     LoginActivity 的 onBackPressed 迁到 OnBackPressedDispatcher), 已进 verify;
#     不许用 lint-baseline/lint.xml 掩盖, 也不许把 error 重新放回 continue-on-error
#     (细节见 notes-wip.md)。
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Android 目标的 Rust 构建要过构建期 bindgen(rquickjs-sys 无 *-linux-android 预生成 bindings)
# ⇒ 所有 gradle 入口都套这层(否则 cc/bindgen 找不到 NDK 与 libclang)。
ANDROID_ENV="$ROOT/tools/android-bindgen-env.sh"

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

# ncm-plugin 不再 --exclude(2026-11-20 切片 2 第一步): `ncm-service` 现在依赖它
# (plugins::ReqwestTransport 实现 ncm-plugin 的 Transport), 它已经是产品依赖图的一部分,
# 所以 rust-lint / rust-test 都按 workspace 全量跑; 原来的独立门 `rust-plugin` 已删除
# (同一口径只留一种实现, 不留双门)。
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

cmd_lock_poison() {
  echo "+ bash tools/check-lock-poison.sh"
  bash "$ROOT/tools/check-lock-poison.sh"
}

cmd_tokens() {
  echo "+ bash tools/check-tokens.sh --strict"
  bash "$ROOT/tools/check-tokens.sh" --strict
}

# 浮层入口门(U-03): 业务代码里不许再直连 showModalBottomSheet / showDialog,
# 只许走 ui/lib/src/app_sheet.dart 的 showAppSheet / showAppDialog。
cmd_sheet_entry() {
  echo "+ bash tools/check-sheet-entry.sh"
  bash "$ROOT/tools/check-sheet-entry.sh"
}

# 全局槽位门(审计 7.6): 进程级 ValueNotifier(顶格声明)只许在"声明它的文件"与
# home/home_wiring.dart 里赋值, 其余地方一律走声明方的 publish* 入口(见脚本头注释)。
cmd_global_slots() {
  echo "+ bash tools/check-global-slots.sh"
  bash "$ROOT/tools/check-global-slots.sh"
}

# 文档门: docs/**/*.md + 仓库根所有 *.md 的相对链接死链, 以及 docs/ 根文件的索引覆盖
# (docs/archive/** 只查链接不查索引)。存量豁免只走 tools/docs-gate-allowlist.txt(理由必填)。
cmd_docs() {
  echo "+ bash tools/check-docs.sh"
  bash "$ROOT/tools/check-docs.sh"
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
  # CI 侧 Maven Central 429 的缓解: 只加 GCS 镜像 + 重试次数, 不改仓库顺序(本机 no-op)
  bash tools/ci-gradle-mirror.sh install
  ( cd ui/android && run "$ANDROID_ENV" ./gradlew :app:testDebugUnitTest --console=plain )
}

cmd_android_lint() {
  cmd_android_prepare
  bash tools/ci-gradle-mirror.sh install
  ( cd ui/android && run "$ANDROID_ENV" ./gradlew :app:lintDebug --console=plain )
}

# ---- Android(设备侧: instrumented test) ----
# P-11 完整版第 ① 步: 设备级案例接进**唯一门禁实现**(之前只能在会话里手跑)。
#
# 为什么默认不进 verify: 要一台在线模拟器(本机 AVD `a34`), 一轮 5~10 分钟,
# 会重建 debug APK + 编 ndk —— 本机硬件不稳的时段不该带在常跑门禁上。
# 约定:
#   ① 没有 emulator 在线 => SKIP(退 0), 接线方不需要写分支;
#   ② `verify` 里只有显式 `NCM_INSTRUMENTED=1` 才跑;
#   ③ 设备纪律复用 `tools/devui/androidtest`(非 emulator 一律拒绝 —— connected* 任务
#      会枚举所有在线设备, 绝不因为插着用户的日常手机就往它上面装测试包)。
cmd_android_instrumented() {
  local dev=${DEV:-}
  command -v adb >/dev/null || {
    echo "SKIP android-instrumented: PATH 里没有 adb(先 source tools/env.sh)"
    return 0
  }
  if [ -z "$dev" ]; then
    dev=$(adb devices | tr -d '\r' | awk '$2 == "device" && $1 ~ /^emulator-/ {print $1; exit}')
  fi
  if [ -z "$dev" ]; then
    echo "SKIP android-instrumented: 没有在线模拟器(起法: nohup ~/bin/avd headless a34 &)"
    return 0
  fi
  cmd_android_prepare
  run env DEV="$dev" bash tools/devui/androidtest "$@"
}

# 【可选】钉死本项目独占实例 emulator-5554(a34)。与 android-instrumented 的区别:
# 那边按 adb devices 顺序挑第一台模拟器, 本机若另起了 a36 会挑错台; 这条只认 5554, 不在线就 SKIP 退 0。
# 不进 verify(要模拟器活着, 一轮 ~30s 构建 + ~16s 用例), 必须显式调用。
cmd_android_test_emu() {
  local dev=${DEV:-emulator-5554}
  command -v adb >/dev/null || {
    echo "SKIP android-test-emu: PATH 里没有 adb(先 source tools/env.sh)"
    return 0
  }
  if ! adb devices | tr -d '\r' | awk -v d="$dev" '$1 == d && $2 == "device" {found=1} END {exit !found}'; then
    echo "SKIP android-test-emu: $dev 不在线(起法: nohup ~/bin/avd headless a34 -gpu swiftshader_indirect -no-snapshot &)"
    return 0
  fi
  cmd_android_prepare
  run env DEV="$dev" bash tools/devui/androidtest "$@"
}

cmd_desktop_smoke() {
  echo "+ bash tools/smoke-desktop-headless(含交互级断言, 本机 ≈60s)"
  local rc=0
  local t0=$(date +%s)
  bash "$ROOT/tools/smoke-desktop-headless" || rc=$?
  echo "desktop-smoke 耗时 $(( $(date +%s) - t0 ))s(rc=$rc)"
  case $rc in
    0) : ;;
    3) echo "SKIP desktop-smoke: 缺 bundle 或 xvfb/dbus(不是失败)" ;;
    *) die "desktop-smoke 失败(rc=$rc)" ;;
  esac
}

cmd_verify() {
  cmd_rust_lint
  cmd_rust_test
  cmd_dart_format
  cmd_dart_analyze
  cmd_write_guard
  cmd_lock_poison
  cmd_tokens
  cmd_row_padding
  cmd_sheet_entry
  cmd_global_slots
  cmd_docs
  cmd_flutter_test
  cmd_android_unit
  cmd_android_lint
  # 设备级案例默认不跑(要模拟器 + 5~10 分钟); 显式 NCM_INSTRUMENTED=1 才带上。
  if [ "${NCM_INSTRUMENTED:-0}" = "1" ]; then
    cmd_android_instrumented
  fi
  # 桌面无头冒烟同理: 需要现成 release bundle, 显式 NCM_DESKTOP_SMOKE=1 才带上。
  if [ "${NCM_DESKTOP_SMOKE:-0}" = "1" ]; then
    cmd_desktop_smoke
  fi
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
  lock-poison)   cmd_lock_poison ;;
  tokens)        cmd_tokens ;;
  row-padding)   cmd_row_padding ;;
  sheet-entry)   cmd_sheet_entry ;;
  global-slots)  cmd_global_slots ;;
  docs|doc)      cmd_docs ;;
  flutter-test)  cmd_flutter_test "$@" ;;
  android-unit)  cmd_android_unit ;;
  android-instrumented) cmd_android_instrumented "$@" ;;
  android-test-emu) cmd_android_test_emu "$@" ;;
  desktop-smoke) cmd_desktop_smoke ;;
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
