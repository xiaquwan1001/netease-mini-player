#!/usr/bin/env bash
# 本地 CI: 离线单测 + 桥接测试 + 两端构建
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
# 代理洁癖: 本机代理端口(7890)常常没起, 死代理会让 reqwest 报
# "error sending request for url (...)", 与"接口挂了/风控"极像。
# 默认在测试阶段清掉代理; 确实要靠代理上网时用 NCM_KEEP_PROXY=1 保留。
if [ "${NCM_KEEP_PROXY:-0}" != "1" ]; then
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
fi
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
