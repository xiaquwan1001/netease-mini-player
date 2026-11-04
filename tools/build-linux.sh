#!/usr/bin/env bash
# 构建 Linux 桌面版(debug). 产物: ui/build/linux/x64/debug/bundle/minincm
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
# 和 ci.sh 一样: 死代理(7890)会让 reqwest 报 "error sending request", 与接口故障极像
if [ "${NCM_KEEP_PROXY:-0}" != "1" ]; then
  unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY
fi
# vendor 的 integration 测试要打真接口(并发/连跑会被风控挂), 不是我们的回归范围
cargo test --manifest-path core/Cargo.toml --workspace --exclude ncm-api-rs
cd ui
flutter test
flutter build linux --debug
echo "OK -> ui/build/linux/x64/debug/bundle/minincm"
