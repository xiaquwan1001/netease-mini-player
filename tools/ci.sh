#!/usr/bin/env bash
# 本地 CI: 离线门(与 GitHub CI 同一套命令) + vendor 联网 smoke + 两端构建。
#
# 门禁命令**不在这里手抄**: 全部转发给 tools/ci-gates.sh(GitHub ci.yml / release.yml
# 调的也是同一个脚本)。这样"本地跑绿"与"CI 跑绿"是同一句话, 不会再出现
# 发版门比 CI 弱、token 门只有本地跑 这类漂移(2026-11-16 平台审计 P-13/P-14)。
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh

# ---- 离线门(与 .github/workflows/ci.yml 的 rust / flutter 两个 job 完全同口径) ----
echo "== rust tests (本地: domain/provider/service/ffi/cli)"
bash tools/ci-gates.sh rust-test

echo "== 格式与 lint 门 (与 CI 同口径)"
bash tools/ci-gates.sh rust-lint

# ---- vendor 匿名联网 smoke(CI 不跑: 需要出口网络, 且允许抖动) ----
echo "== rust tests (vendor 匿名联网 smoke)"
# vendor(ncm-api-rs) 的 tests/integration.rs 是 4 例匿名真实联网 smoke, 高频繁跑会被上游
# 风控/公网抖动弹回非 200(与改动无关, 2026-11-07 实测: 同一轮内不同用例随机挂)。
# 所以它只是"允许抖动"的 smoke, 不阻塞收口; 严格核验公网链路用 NCM_VENDOR_SMOKE_STRICT=1。
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

echo "== write-guard (测试不得直连写接口)"
bash tools/ci-gates.sh write-guard

echo "== design token 门 (间距/圆角/字号只允许有限集合)"
# 集合外的数值(14/18/circular(3)/fontSize: 8)是"说不上来但不协调"的主要来源。
# 2026-11-13 基线已清零(20 处全部收敛或按 `// token-ok: 理由` 显式例外), 现在阻塞。
bash tools/ci-gates.sh tokens

echo "== 文档门 (相对链接死链 + docs 根索引)"
bash tools/ci-gates.sh docs

echo "== dart 格式 + analyze"
bash tools/ci-gates.sh dart-format
bash tools/ci-gates.sh dart-analyze

# ---- 以下需要真实构建产物, CI 的 build-* job 各自覆盖, 本地串起来跑 ----
echo "== 全量测试(含 golden, 只排 network)"
( cd ui && flutter pub get )
bash tools/ci-gates.sh flutter-test

echo "== bridge test (loads cdylib directly)"
cargo build -p ncm_ffi --manifest-path core/Cargo.toml

echo "== build linux"
( cd ui && flutter build linux --debug )

echo "== build android"
( cd ui && flutter build apk --debug )

echo "CI OK"
