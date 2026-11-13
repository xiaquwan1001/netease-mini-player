#!/usr/bin/env bash
# 网易云接口覆盖率: vendor/ncm-api 里有多少 endpoint, 我们实际用了多少, 差集是什么.
# 用法: bash tools/api-coverage.sh [--list]
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - "$@" <<'PY'
import os, re, sys
from pathlib import Path

VENDOR = "core/vendor/ncm-api/src/api"
# provider 实现 2026-11-2x 起按能力域拆成模块目录(netease/mod.rs + netease/*.rs);
# 单文件时代遗留路径仍兼容, 便于对老 tag 跑同一份统计.
SERVICE = Path("core/crates/ncm-service/src/netease.rs")
FFI = "core/crates/ncm-ffi/src/api.rs"
UI = "ui/lib"

# mod.rs 是模块清单本身, 不是 endpoint, 不计入统计
all_endpoints = sorted(f[:-3] for f in os.listdir(VENDOR) if f.endswith(".rs") and f != "mod.rs")
if SERVICE.is_file():
    src = SERVICE.read_text()
else:
    src = "".join(p.read_text() for p in sorted(SERVICE.with_suffix("").rglob("*.rs")))
# 跨行也认: client \n  .method(
used = sorted(set(re.findall(r"client\s*\.\s*([a-z0-9_]+)\s*\(", src)))
used = [m for m in used if m in all_endpoints]
unused = [m for m in all_endpoints if m not in used]

# FFI 导出 vs UI 调用(Dart 侧是 camelCase)
ffi = sorted(set(re.findall(r"^pub (?:async )?fn ([a-z0-9_]+)", open(FFI).read(), re.M)))
def camel(s):
    p = s.split("_")
    return p[0] + "".join(x[:1].upper() + x[1:] for x in p[1:])
ui_text = "".join(
    p.read_text() for p in __import__("pathlib").Path(UI).rglob("*.dart")
    if "/src/rust/" not in str(p)
)
# 大小写不敏感匹配: frb 生成名不总是严格 camelCase(实测 lyric_lines_i18n -> lyricLinesI18N,
# 大写 N), 按 camel 精确匹配会把它误判成"无 UI 入口"。这里统一小写化后比对标识符集合。
ui_idents = {m.lower() for m in re.findall(r"rust\.([A-Za-z0-9_]+)", ui_text)}
no_ui = [f for f in ffi if camel(f).lower() not in ui_idents]

print(f"vendor endpoint 模块 : {len(all_endpoints)}")
print(f"service 已调用        : {len(used)}  ({len(used) * 100 // max(len(all_endpoints), 1)}%)")
print(f"未接入               : {len(unused)}")
print(f"FFI 导出函数          : {len(ffi)}")
print(f"其中 UI 没有入口      : {len(no_ui)} -> {' '.join(no_ui) if no_ui else '(无)'}")

if "--list" in sys.argv:
    print()
    print("== 已接入 ==")
    print(" ".join(used))
    print()
    print("== 未接入 ==")
    for i, m in enumerate(unused, 1):
        print(f"{i:>3}. {m}")
PY
