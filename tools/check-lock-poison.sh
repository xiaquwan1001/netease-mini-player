#!/usr/bin/env bash
# 门禁: 生产代码里不得出现 `lock().unwrap()` / `lock().expect(..)`(锁中毒会让整个进程连锁 panic).
#
# 背景(docs/remaining-batches.md §12 / .pi/plans/arch-audit-backend-2026-11-15.md §4.1):
# ncm-service 里任一持锁线程 panic 后 Mutex 永久 poisoned, 之后所有 `lock().unwrap()` 连锁 panic ——
# 一个后台线程的小 bug 会升级成整个 App 崩溃。审计时 ncm-service 有 25 处, 现已清零;
# 正确写法是 `lock().map_err(|e| e.to_string())`(ncm-ffi 口径)或
# `lock().unwrap_or_else(|e| e.into_inner())`(中毒即续用, 适合状态缓存类锁)。
#
# 允许范围: `#[cfg(test)]` 模块内(测试自己就是进程边界, 中毒即失败更快)。
# 判定是启发式(花括号计数找 `#[cfg(test)] mod xxx { ... }` 区间), 不是语法分析:
# 够用且可读; 万一误判, 把那行改成具名 helper 即可。
set -euo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import re, sys, pathlib

pattern = re.compile(r"\.lock\(\)\s*\.(?:unwrap|expect)\(")
root = pathlib.Path("core/crates")
violations = []
allowed_in_tests = 0

def test_spans(lines):
    """返回 [(start, end)] —— #[cfg(test)] mod 覆盖的行号区间(1-based, 含端点)."""
    spans = []
    depth = 0
    pending_test = False
    open_start = None
    open_depth = None
    for i, line in enumerate(lines, 1):
        if "#[cfg(test)]" in line:
            pending_test = True
        if pending_test and re.search(r"\bmod\s+\w+", line) and "{" in line:
            open_start = i
            open_depth = depth          # 该 mod 行之前的花括号深度
            pending_test = False
        depth += line.count("{") - line.count("}")
        if open_start is not None and depth == open_depth and i >= open_start:
            spans.append((open_start, i))
            open_start = None
    if open_start is not None:
        spans.append((open_start, len(lines)))
    return spans

for path in sorted(root.rglob("*.rs")):
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        continue
    spans = test_spans(lines)
    for i, line in enumerate(lines, 1):
        if not pattern.search(line):
            continue
        if any(a <= i <= b for a, b in spans):
            allowed_in_tests += 1
        else:
            violations.append((path, i, line.strip()))

if violations:
    print("::error::生产代码里出现 lock().unwrap()/expect(锁中毒会连锁 panic):")
    for path, line, text in violations:
        print(f"  {path}:{line}: {text}")
    print("改法: lock().map_err(|e| e.to_string())? 或 lock().unwrap_or_else(|e| e.into_inner())")
    sys.exit(1)

print(f"lock-poison: OK(生产代码 0 处; 测试内 {allowed_in_tests} 处放行)")
PY
