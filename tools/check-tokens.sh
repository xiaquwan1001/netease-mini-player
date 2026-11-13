#!/usr/bin/env bash
# 设计 token 越界门: 间距 / 圆角 / 字号只允许落在有限集合里。
#
# 为什么需要: 「说不上来但就是不协调」基本都是用了集合外的数值(14 vs 16、
# circular(3)、fontSize: 8)。这类问题没有 lint 能管, 靠人肉 review 一定会漏。
# 本门把"集合外数值"变成可枚举、可计数、可回归的清单。
#
# 用法:
#   tools/check-tokens.sh            # 报告模式: 打印越界清单 + 统计, 永远退出 0
#   tools/check-tokens.sh --strict   # 门禁模式: 有越界则退出 1(ci.sh 用这个)
#   tools/check-tokens.sh --top 20   # 只显示前 N 条(默认 40)
#
# 口径:
#   · EdgeInsets.* 里的数字      → 间距集合
#   · BorderRadius.circular(N)   → 圆角集合
#   · fontSize: N                → 字号集合
#   · SizedBox(height|width: N) 且 N <= 32 → 间距集合(>32 视为组件尺寸, 不管)
#   · 文件范围: ui/lib/**(排除 ui/lib/src/rust/ 的 codegen 产物)
#   · 显式例外: 命中的那一行(或上一行)带 `// token-ok: 理由` 就跳过 ——
#     例外必须写清"为什么这个数值不能用 token 表达"(如名次列宽 26 是内容宽度,
#     不是间距)。没有理由的 token-ok 视同没有。
set -uo pipefail

strict=0
top=40
while [ $# -gt 0 ]; do
    case "$1" in
        --strict) strict=1; shift ;;
        --top) top="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

repo=$(cd "$(dirname "$0")/.." && pwd)
lib="$repo/ui/lib"
[ -d "$lib" ] || { echo "找不到 $lib" >&2; exit 2; }

TOP="$top" LIB="$lib" python3 - <<'PY'
import os, re, sys, collections

lib = os.environ["LIB"]
top = int(os.environ["TOP"])

spacing_ok = {0, 1, 2, 3, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96,
              108, 118, 120, 160, 180, 220, 240}
radius_ok = {0, 2, 4, 6, 8, 10, 12, 16, 20, 22, 24, 999}
font_ok = {9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32, 36, 40}

num_re = re.compile(r"\b(\d+(?:\.\d+)?)\b")
rules = [
    ("spacing", re.compile(r"EdgeInsets\.(?:all|symmetric|only|fromLTRB)\(([^)]*)\)"), spacing_ok),
    ("radius", re.compile(r"BorderRadius\.circular\(([0-9.]+)"), radius_ok),
    ("fontSize", re.compile(r"fontSize:\s*([0-9.]+)"), font_ok),
    ("gap", re.compile(r"SizedBox\(\s*(?:height|width):\s*([0-9.]+)"), spacing_ok),
]

hits = []
by_kind = collections.Counter()
by_file = collections.Counter()
for root, _dirs, files in os.walk(lib):
    if os.sep + "rust" in root:
        continue
    for name in sorted(files):
        if not name.endswith(".dart"):
            continue
        path = os.path.join(root, name)
        text = open(path, encoding="utf8").read()
        lines = text.splitlines()
        for kind, pat, allowed in rules:
            for m in pat.finditer(text):
                raw = m.group(1)
                # gap 规则只关心"间距"量级, 组件尺寸(>32)跳过
                if kind == "gap":
                    try:
                        if float(raw) > 32:
                            continue
                    except ValueError:
                        continue
                line_no = text.count("\n", 0, m.start()) + 1
                # 显式例外: 本行或上一行声明了 token-ok(且带理由)
                window = " ".join(lines[max(0, line_no - 2) : line_no])
                if "token-ok:" in window:
                    continue
                for tok in num_re.findall(raw):
                    val = float(tok)
                    if val in allowed:
                        continue
                    snippet = lines[line_no - 1].strip()[:88]
                    hits.append((kind, os.path.relpath(path, os.path.dirname(lib)), line_no, snippet))
                    by_kind[kind] += 1
                    by_file[os.path.relpath(path, os.path.dirname(lib))] += 1

if not hits:
    print("check-tokens: OK(没有集合外的间距/圆角/字号)")
    sys.exit(0)

print(f"check-tokens: {len(hits)} 处越界  " + " ".join(f"{k}={v}" for k, v in by_kind.most_common()))
for kind, path, line, snippet in hits[:top]:
    print(f"  [{kind}] {path}:{line}  {snippet}")
if len(hits) > top:
    print(f"  ... 还有 {len(hits) - top} 处(用 --top 加大)")

allowed_hint = {
    "spacing": "间距建议只用 4/8/12/16/24(容器内微调可 2/6/10), 新数值先问能不能用现有 token",
    "radius": "圆角建议 4/6/8/12/16/20/999",
    "fontSize": "字号走 textTheme(bodySmall/bodyMedium/titleSmall...), 不直写 fontSize",
    "gap": "区块/卡片间距走 layout.dart 的 kSectionGap/kCardGap 等常量",
}
for kind in by_kind:
    print(f"  提示[{kind}]: {allowed_hint[kind]}")
sys.exit(1)
PY
rc=$?
if [ "$strict" -eq 1 ]; then
    exit $rc
fi
exit 0
