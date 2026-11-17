#!/usr/bin/env bash
# 列表行留白一致性门(列表行审计 C 级, 2026-11-17): 行留白只允许用 layout.dart 的具名口径。
#
# 为什么需要: check-tokens.sh 只管"数值在不在白名单里", 而 C 级的问题恰恰是
# **同一个语义用了不同的合法数值** —— 歌曲行曾有 12/0/4、8/0/4、4/0/4、16/16(
# Material 默认)、0/6 五种并存, 同一页里上一行 16 下一行 12(或 12 + 16 = 28 的
# 三重叠加)。数值全合法, 所以没有一道门能拦住它; 这里把"语义 → 常量"变成可枚举清单。
#
# 用法:
#   tools/check-row-padding.sh            # 报告模式: 打印清单 + 计数, 永远退出 0
#   tools/check-row-padding.sh --strict   # 门禁模式: 有未登记口径则退出 1(ci-gates.sh 用)
#
# 扫描对象(只这两类, 不碰卡片/页面 padding):
#   · `contentPadding: <expr>` —— ListTile 行(行级留白的唯一入口)
#   · `SongRow(...)` / `SongTile(...)` 调用里的 `padding: <expr>`
#
# 口径:
#   · 白名单 = layout.dart 的 kPageRowPadding / kCardRowPadding / kPreviewRowPadding,
#     以及 `EdgeInsets.zero`(父容器已内缩时贴线, 必须写理由)。
#     已经删除的 kSongRowPadding(8/0/4) 故意**不在**白名单里: 谁再写它就会被判未登记。
#   · 显式例外: 命中那行(或上一行)带 `// token-ok: 理由` 就跳过, 与 check-tokens.sh 同规则
#   · 传参转发(`padding: padding`)不算越界: 值由调用点决定, 由调用点负责登记
set -uo pipefail

strict=0
while [ $# -gt 0 ]; do
    case "$1" in
        --strict) strict=1; shift ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

repo=$(cd "$(dirname "$0")/.." && pwd)
lib="$repo/ui/lib"

STRICT="$strict" LIB="$lib" python3 - <<'PY'
import os, re, sys
from pathlib import Path

lib = Path(os.environ["LIB"])
strict = os.environ["STRICT"] == "1"

REGISTRY = {
    "kPageRowPadding",      # 整页铺满(12/0/4, 与页面线共线): 歌曲行也是它
    "kCardRowPadding",      # 父容器已内缩 12, 行再缩 4(叠出 16)
    "kPreviewRowPadding",   # 父容器已内缩, 行内不再加左右边(0/6)
    "EdgeInsets.zero",      # 父容器已内缩且行首应贴线 —— 必须带 token-ok 理由
}
PASSTHROUGH = {"padding", "contentPadding"}

row_call = re.compile(r"\b(ListTile|SongRow|SongTile)\(")

def block_of(src: str, start: int) -> str:
    """返回 `(` 之后到配对 `)` 之前的源码块。"""
    i, depth = start, 1
    while i < len(src) and depth:
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
        i += 1
    return src[start: i]

def norm(expr: str) -> str:
    expr = expr.strip()
    if expr.startswith("const "):
        expr = expr[len("const "):].strip()
    return expr

# 转发/条件表达式不算越界: 值由调用点或条件决定, 由真正写字面量那处负责登记。
PASSTHROUGH_LIKE = re.compile(r"(==|\?|\bpadding\b\s*,)")

def has_reason(lines, idx) -> bool:
    # 允许挂在同一行或紧邻上面两行(注释块写成两行很常见)
    for i in (idx, idx - 1, idx - 2, idx - 3):
        if 0 <= i < len(lines) and "token-ok:" in lines[i]:
            return True
    return False

hits = []          # (file, line, expr, reasoned)
counts = {}
for path in sorted(lib.rglob("*.dart")):
    rel = path.relative_to(lib.parent.parent)
    if "/src/rust/" in str(rel):
        continue
    src = path.read_text()
    lines = src.splitlines()

    for m in row_call.finditer(src):
        block = block_of(src, m.end())
        for pm in re.finditer(r"\b(contentPadding|padding):\s*([^,\n]+(?:\([^()]*\))?)", block):
            # 只看**行自己那一层**的参数: 嵌在 `styleFrom(` / `InputDecoration(` /
            # 另一个 `Padding(` 里的 padding 是控件自己的, 不是行留白。
            depth = block[: pm.start()].count("(") - block[: pm.start()].count(")")
            if depth != 0:
                continue
            expr = norm(pm.group(2))
            line_no = src[: m.end() + pm.start()].count("\n")
            hits.append((str(rel), line_no + 1, expr, has_reason(lines, line_no)))


bad = []
for rel, line, expr, reasoned in hits:
    passthrough = expr in PASSTHROUGH or PASSTHROUGH_LIKE.search(expr)
    # EdgeInsets.zero 也要求理由: 它是「父容器已内缩」的正确写法, 但必须写清凭什么
    needs_reason = expr == "EdgeInsets.zero"
    if expr not in REGISTRY and not passthrough and not reasoned:
        bad.append((rel, line, expr))
    elif needs_reason and not reasoned:
        bad.append((rel, line, expr))
    counts[expr] = counts.get(expr, 0) + 1

print(f"check-row-padding: 扫描 {len(hits)} 处行留白({len(counts)} 种口径)")
for expr, n in sorted(counts.items(), key=lambda kv: -kv[1]):
    passthrough = expr in PASSTHROUGH or PASSTHROUGH_LIKE.search(expr)
    mark = "" if expr in REGISTRY or passthrough else "  <- 未登记"
    print(f"  {n:3d}  {expr}{mark}")
if bad:
    print(f"\n未登记口径({len(bad)} 处, 需改成 layout.dart 常量或补 `// token-ok: 理由`):")
    for rel, line, expr in bad:
        print(f"  {rel}:{line}  {expr}")
else:
    print("\n所有行留白都在 layout.dart 的具名口径里")

if strict and bad:
    sys.exit(1)
PY
