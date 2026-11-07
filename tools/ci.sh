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
echo "== rust tests (本地: domain/provider/service/ffi/cli)"
# vendor(ncm-api-rs) 的 tests/integration.rs 是 8 例**匿名真实联网 smoke**,
# 高频繁跑会被上游风控/公网抖动弹回非 200, 与本次改动无关(2026-11-07 实测:
# 同一轮内不同用例随机挂)。所以它单独作为"允许抖动"的 smoke, 不阻塞收口;
# 需要严格核验公网链路时用 NCM_VENDOR_SMOKE_STRICT=1 跑。
cargo test --manifest-path core/Cargo.toml --workspace --exclude ncm-api-rs
echo "== rust tests (vendor 匿名联网 smoke)"
smoke_ok=0
for i in 1 2 3; do
  if cargo test --manifest-path core/Cargo.toml -p ncm-api-rs --test integration; then
    smoke_ok=1
    break
  fi
  echo "   vendor smoke 第 $i 次失败(匿名接口抖动), 重试..."
done
if [ "$smoke_ok" != 1 ]; then
  if [ "${NCM_VENDOR_SMOKE_STRICT:-0}" = "1" ]; then
    echo "vendor smoke 连续 3 次失败且 NCM_VENDOR_SMOKE_STRICT=1" >&2
    exit 1
  fi
  echo "WARN: vendor 匿名联网 smoke 连续 3 次失败(已知上游风控/公网抖动, 不阻塞); 复核: NCM_VENDOR_SMOKE_STRICT=1 tools/ci.sh"
fi

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
