#!/usr/bin/env bash
# 构建 Linux 桌面版(debug). 产物: ui/build/linux/x64/debug/bundle/minincm
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/env.sh
cargo test --manifest-path core/Cargo.toml
cd ui
flutter test
flutter build linux --debug
echo "OK -> ui/build/linux/x64/debug/bundle/minincm"
