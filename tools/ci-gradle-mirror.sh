#!/usr/bin/env bash
# 把 Maven Central 的 GCS 镜像 init 脚本装进 Gradle 的用户级 init.d(只影响这台机器上的 **CI** 运行)。
#
# 背景: GitHub 共享 runner 的出口 IP 会被 Maven Central 限流(429 Too Many Requests), Gradle 在
# 配置阶段就失败 ⇒ 先渲染 `tools/ci-maven-gcs-mirror.gradle` 到 `$GRADLE_USER_HOME/init.d/`,
# 再跑构建。**不改** ui/android/settings.gradle.kts 的仓库顺序(纪律见 .pi/memory/notes-build.md)。
#
# 用法:
#   bash tools/ci-gradle-mirror.sh install     # 仅在 GITHUB_ACTIONS=true 时真的安装(本地 no-op)
#   bash tools/ci-gradle-mirror.sh install --force   # 本机也装(手工排查 429 时用)
#   bash tools/ci-gradle-mirror.sh status
#   bash tools/ci-gradle-mirror.sh uninstall
#
# 幂等: 重复 install 只是覆盖同一份文件, 可安全地放进每个比 Android 目标的 job。
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="tools/ci-maven-gcs-mirror.gradle"
GRADLE_HOME_DIR="${GRADLE_USER_HOME:-$HOME/.gradle}"
INIT_DIR="$GRADLE_HOME_DIR/init.d"
DEST="$INIT_DIR/zz-ci-maven-gcs-mirror.gradle"

cmd="${1:-install}"
force=0
[ "${2:-}" = "--force" ] && force=1

case "$cmd" in
  install)
    if [ "${GITHUB_ACTIONS:-}" != "true" ] && [ "$force" -eq 0 ]; then
      echo "ci-gradle-mirror: 非 CI 环境(GITHUB_ACTIONS!=true), 跳过安装(本机继续走自己的镜像)"
      exit 0
    fi
    [ -f "$SRC" ] || { echo "ci-gradle-mirror: 缺 $SRC" >&2; exit 1; }
    mkdir -p "$INIT_DIR"
    # zz- 前缀: init.d 按文件名排序加载, 放最后便于在日志里辨认
    cp "$SRC" "$DEST"
    echo "ci-gradle-mirror: 已安装 -> $DEST"
    # 429 是瞬时限流, 让 Gradle 自己多试两次(仍不改仓库顺序)
    PROPS="$GRADLE_HOME_DIR/gradle.properties"
    if ! grep -q 'org.gradle.internal.repository.max.retries' "$PROPS" 2>/dev/null; then
      printf 'systemProp.org.gradle.internal.repository.max.retries=3\n' >> "$PROPS"
      echo "ci-gradle-mirror: 已在 $PROPS 加 max.retries=3"
    fi
    ;;
  uninstall)
    rm -f "$DEST"
    echo "ci-gradle-mirror: 已移除 $DEST"
    ;;
  status)
    if [ -f "$DEST" ]; then echo "installed: $DEST"; else echo "not installed"; fi
    grep -n 'max.retries' "$GRADLE_HOME_DIR/gradle.properties" 2>/dev/null || echo "max.retries: 未设置"
    ;;
  *)
    echo "用法: bash tools/ci-gradle-mirror.sh {install [--force]|uninstall|status}" >&2
    exit 2
    ;;
esac
