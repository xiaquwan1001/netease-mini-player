#!/usr/bin/env bash
# 本地 CI: 离线单测 + 桥接测试 + 两端构建
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
echo "== rust tests"
cargo test --manifest-path core/Cargo.toml
echo "== flutter analyze"
(cd ui && flutter analyze --no-fatal-infos)
echo "== bridge test (loads cdylib directly)"
cargo build -p ncm_ffi --manifest-path core/Cargo.toml
(cd ui && flutter test)
echo "== build linux"
(cd ui && flutter build linux --debug)
echo "== build android"
(cd ui && flutter build apk --debug)
echo "CI OK"
