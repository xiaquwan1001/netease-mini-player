#!/usr/bin/env bash
# 文档门: 相对链接死链 + docs/ 根目录索引覆盖率。
#
# 为什么要有这道门(2026-11-19): docs/ 在两天里做了 3 次大批量搬迁/合并(31 份 plans 归档、
# 10 份批次笔记合成 1 份、5 份根目录归档件移入 archive/), 每次都靠临时脚本自证一次,
# 临时脚本随 /tmp 一起没了 ⇒ 下一次搬迁又得现写。这道门把那次自证固化下来。
#
# 两条检查(都只看**相对** markdown 链接, 外链/锚点不校验):
#   ① 死链: `docs/**/*.md` 与仓库根目录的**所有** `*.md`(README / README.en / CONTRIBUTING /
#      AGENTS / THIRD_PARTY_NOTICES)里的 `[text](path)` / `![alt](path)` 的
#      **文件部分**必须存在(锚点 `#fragment` 丢弃后再判; 目录链接要求目录存在)。
#   ② 索引: `docs/` 根(**不递归**)的每个 `.md` 都必须被 `docs/README.md` 链接到。
#      `docs/archive/**` 只查 ①, 不强制进索引(归档件本来就只留痕)。
#
# 白名单: `tools/docs-gate-allowlist.txt`, 每条 `kind | subject | 理由`, 理由必填 ——
# 没有理由的行会被当语法错误直接 FAIL, 不允许「静默跳过」。
#
# 用法:
#   bash tools/check-docs.sh                # = --check, 退出码 0=PASS 1=FAIL
#   bash tools/check-docs.sh --check        # 同上
#   bash tools/check-docs.sh --fix-index    # 只打印「该往 docs/README.md 补哪几行」, 不改文件
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

MODE=check
case "${1:---check}" in
  --check) MODE=check ;;
  --fix-index) MODE=fix-index ;;
  -h|--help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    echo "用法: $0 [--check|--fix-index]" >&2
    exit 2
    ;;
esac

exec python3 - "$ROOT" "$MODE" <<'PY'
import os
import re
import sys
import urllib.parse

ROOT = sys.argv[1]
MODE = sys.argv[2]
ALLOWLIST = os.path.join(ROOT, "tools", "docs-gate-allowlist.txt")
INDEX = os.path.join(ROOT, "docs", "README.md")

LINK_RE = re.compile(r"!?\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+\"[^\"]*\")?\s*\)")
SKIP_SCHEMES = ("http://", "https://", "mailto:", "tel:", "ftp://", "ftp:", "data:", "irc:", "ircs:")


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, "/")


def strip_noise(text):
    """逐行去掉围栏代码块 / HTML 注释 / 行内代码 —— 里面的 [a, b] 不是链接。

    必须按行扫而不是整篇正则: docs 里有大量代码块, 整篇非贪婪配对一旦错位,
    行内代码的配对被带跑, 会出现 `[start,duration](wStart,wDur,0)` 这种假死链。
    """
    out = []
    fence = None  # 当前围栏标记(``` 或 ~~~ 的原文)
    in_comment = False
    for line in text.splitlines():
        stripped = line.lstrip()
        if fence is not None:
            if stripped.startswith(fence):
                fence = None
            continue
        if not in_comment:
            m = re.match(r"(`{3,}|~{3,})", stripped)
            if m:
                fence = m.group(1)
                continue
        if in_comment:
            if "-->" in line:
                in_comment = False
                line = line.split("-->", 1)[1]
            else:
                continue
        line = re.sub(r"<!--.*?-->", "", line)
        if "<!--" in line:
            line = line.split("<!--", 1)[0]
            in_comment = True
        line = re.sub(r"`+[^`]*`+", "", line)
        out.append(line)
    return "\n".join(out)


def links_of(path):
    with open(path, encoding="utf-8") as fh:
        text = strip_noise(fh.read())
    out = []
    for m in LINK_RE.finditer(text):
        url = m.group(1)
        if url.startswith("#") or url.startswith("//"):
            continue
        if url.startswith(SKIP_SCHEMES):
            continue
        if url.startswith("/"):
            continue  # 站内绝对路径, 与仓库布局无关
        target = url.split("#")[0].split("?")[0]
        target = urllib.parse.unquote(target).strip()
        if not target:
            continue
        out.append((url, target))
    return out


def load_allowlist():
    entries = {}
    errors = []
    if not os.path.exists(ALLOWLIST):
        return entries, errors
    with open(ALLOWLIST, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = [p.strip() for p in line.split("|")]
            if len(parts) < 3 or not parts[2] or parts[0] not in ("dead-link", "index"):
                errors.append(
                    f"{rel(ALLOWLIST)}:{lineno}: 语法错误(应为 `dead-link|index | subject | 理由`, 理由必填): {line}"
                )
                continue
            entries[(parts[0], parts[1])] = parts[2]
    return entries, errors


def walk_markdown():
    files = sorted(
        os.path.join(ROOT, n) for n in os.listdir(ROOT) if n.endswith(".md")
    )
    docs = os.path.join(ROOT, "docs")
    for dirpath, dirnames, filenames in os.walk(docs):
        dirnames.sort()
        for name in sorted(filenames):
            if name.endswith(".md"):
                files.append(os.path.join(dirpath, name))
    return [p for p in files if os.path.exists(p)]


def main():
    allow, allow_errors = load_allowlist()
    violations = list(allow_errors)  # 白名单本身的语法错误也算违规
    used_allow = set()

    # ① 死链
    for path in walk_markdown():
        base = os.path.dirname(path)
        for url, target in links_of(path):
            resolved = os.path.normpath(os.path.join(base, target))
            if os.path.exists(resolved):
                continue
            key = ("dead-link", f"{rel(path)} -> {target}")
            if key in allow:
                used_allow.add(key)
                continue
            violations.append(f"死链: {rel(path)} -> {target}" + (f"  (原文 {url})" if url != target else ""))

    # ② docs/ 根索引覆盖
    missing_index = []
    if os.path.exists(INDEX):
        indexed = set()
        for _url, target in links_of(INDEX):
            indexed.add(os.path.normpath(os.path.join(os.path.dirname(INDEX), target)))
        for name in sorted(os.listdir(os.path.join(ROOT, "docs"))):
            if not name.endswith(".md") or name == "README.md":
                continue
            path = os.path.join(ROOT, "docs", name)
            if not os.path.isfile(path) or path in indexed:
                continue
            key = ("index", rel(path))
            if key in allow:
                used_allow.add(key)
            else:
                missing_index.append(rel(path))
    else:
        violations.append("死链: docs/README.md 不存在(它是 docs/ 的唯一索引)")

    for path in missing_index:
        violations.append(f"未进索引: {path}  (docs/README.md 里没有任何链接指向它)")

    stale = sorted(set(allow) - used_allow)

    # --fix-index: 只打印建议行, 不改文件
    if MODE == "fix-index" and missing_index:
        print("建议在 docs/README.md 对应分节补上(用途/最后更新请自行填实):")
        for path in missing_index:
            name = os.path.basename(path)
            titles = {
                "PROGRESS.md": "进度总账",
                "remaining-batches.md": "待办与分批规划",
                "README.md": "文档索引",
            }
            print(f"| [{name}]({name}) | {titles.get(name, '<一句话用途>')}。**活跃** | <YYYY-MM-DD> |")

    if violations:
        print("FAIL docs-gate")
        for item in violations:
            print(f"  - {item}")
        print(f"共 {len(violations)} 条违规(白名单命中 {len(used_allow)} 条 / 白名单总数 {len(allow)})")
        return 1

    print(
        f"PASS docs-gate: 相对链接死链 0 · docs 根未进索引 {len(missing_index)}"
        f" · 白名单命中 {len(used_allow)}/{len(allow)}"
    )
    if stale:
        print("提示: 以下白名单条目已不再命中, 可删掉: " + ", ".join(f"{k}:{v}" for k, v in stale))
    return 0


sys.exit(main())
PY
