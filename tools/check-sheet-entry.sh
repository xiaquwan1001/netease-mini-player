#!/usr/bin/env bash
# 门禁: 浮层(sheet / dialog)只许经 ui/lib/src/app_sheet.dart 的两个入口打开。
#
# 为什么需要(U-03, 2026-11-18): 全仓曾有 38 处 showModalBottomSheet / showDialog 直接调用
# (sheet 20 + dialog 18, 25 个文件), 各写各的 isScrollControlled / showDragHandle /
# barrierDismissible —— 默认值漂移过几次, 切 tab 收起浮层(U-01/U-02)也只能靠
# "它们恰好是 PopupRoute"兜住。收口到 showAppSheet / showAppDialog 之后, "谁还直连"
# 必须能被 CI 拦住, 否则下一批新代码又会散回去。
#
# 口径:
#   · 扫描 ui/lib/src/**(生产代码); 命中的是**真实调用**(函数名 + 可选泛型实参 + "("),
#     注释/文档里提到 showModalBottomSheet 不算(名字后面没有括号)。
#   · 白名单(允许直连):
#       ui/lib/src/app_sheet.dart     —— 入口本身
#       ui/lib/src/popup_routes.dart  —— 造 route 的底层扳手
#       ui/test/**                    —— 测试要构造"裸"浮层来验证登记表/遮罩(不在本脚本扫描范围)
#   · 待迁移(U-03 第二批, 别的车道在改): mine_view.dart / app_shell.dart /
#     detail/podcast_detail_page.dart / home/** —— 列在 PENDING 里, 且**条数不许增长**
#     (PENDING_EXPECT 是冻结值); 第二批落地后把它们从 PENDING 删掉、把 PENDING_EXPECT 减到 0。
#
# 用法:
#   tools/check-sheet-entry.sh            # 门禁模式: 有违规退出 1
#   tools/check-sheet-entry.sh --self-test # 负向自测: 临时插一处直连, 断言报红
set -uo pipefail
cd "$(dirname "$0")/.."

self_test=0
for arg in "$@"; do
  case "$arg" in
    --self-test) self_test=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

LIB="ui/lib/src"
ALLOW='^(ui/lib/src/app_sheet\.dart|ui/lib/src/popup_routes\.dart):'
PENDING='^ui/lib/src/(mine_view|app_shell)\.dart:|^ui/lib/src/detail/podcast_detail_page\.dart:|^ui/lib/src/home/'
PENDING_EXPECT=7

# 真实调用 = 函数名 + 可选泛型实参 + "(" ; 只提名字(注释/文档)不匹配。
PATTERN='\b(showModalBottomSheet|showDialog|showGeneralDialog|showBottomSheet)[[:space:]]*(<[^>]*>)?[[:space:]]*\('

scan() {
  rg -n --no-heading -e "$PATTERN" "$LIB" 2>/dev/null | grep -Ev "$ALLOW" || true
}

if [ "$self_test" = 1 ]; then
  tmp="$LIB/_sheet_entry_selftest_tmp.dart"
  trap 'rm -f "$tmp"' EXIT
  cat > "$tmp" <<'DART'
// check-sheet-entry.sh --self-test 的临时文件(退出时自动删除)
// ignore_for_file: unused_import
import 'package:flutter/material.dart';

Future<void> selftest(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (_) => const SizedBox.shrink(),
  );
}
DART
  if [ -n "$(scan | grep -Ev "$PENDING")" ]; then
    echo "OK: self-test 生效(临时文件里的直连调用被抓到)"
    exit 0
  fi
  echo "::error::self-test 失败 —— 插进去的直连调用没被抓到(正则或白名单写错了)"
  exit 1
fi

pending=$(scan | grep -E "$PENDING" || true)
violations=$(scan | grep -Ev "$PENDING" || true)
n_pending=$(printf '%s' "$pending" | grep -c . || true)

if [ "$n_pending" -gt "$PENDING_EXPECT" ]; then
  echo "::error::待迁移清单(U-03 第二批)从 $PENDING_EXPECT 处涨到 $n_pending 处 —— 新代码不许再直连:"
  echo "$pending"
  exit 1
fi

if [ -n "$violations" ]; then
  echo "::error::浮层直连(必须走 ui/lib/src/app_sheet.dart 的 showAppSheet / showAppDialog):"
  echo "$violations"
  echo
  echo "  sheet:  showModalBottomSheet<T>(context: ctx, builder: b)"
  echo "       => showAppSheet<T>(ctx, builder: b)"
  echo "          (少数派显式写 isScrollControlled: false / showDragHandle: false)"
  echo "  dialog: showDialog<T>(context: ctx, builder: b)"
  echo "       => showAppDialog<T>(ctx, builder: b)"
  exit 1
fi

if [ "$n_pending" -gt 0 ]; then
  echo "OK: 白名单外 0 处直连; 待 U-03 第二批迁移 $n_pending 处(冻结上限 $PENDING_EXPECT):"
  echo "$pending" | sed 's/^/  /'
else
  echo "OK: ui/lib/src 的浮层全部经 app_sheet.dart 入口(白名单: app_sheet.dart / popup_routes.dart / ui/test)"
fi
