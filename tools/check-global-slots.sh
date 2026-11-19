#!/usr/bin/env bash
# 门禁: 进程级全局槽位(顶层 ValueNotifier)只许在"声明它的文件"与壳层装配文件
# home/home_wiring.dart 里直接赋值; 其余地方一律走声明方暴露的 publish* 入口。
#
# 为什么需要(审计 7.6, 2026-11-20): 全仓有 9 个进程级 ValueNotifier(动作宿主 /
# 页面层数 / 弹层在场 / 播放条槽位 · 数据 · 回调 / 全局"正在播放" / 取链提示 /
# 右栏详情)。它们的监听者都在**祖先**或**Navigator 之外**, 在 build 里同步写就是
# markNeedsBuild 祖先("setState() called during build"), 而帧后写又多一条时效性:
# 页面可能已经销毁, 旧实例的闭包会把死页面的状态写进全局槽位。所以每条写入都必须
# 过 runPostFrameIfAlive(context, ...)(lifecycle_guard.dart)—— 但此前这件事**靠人
# 记**: 谁新加一处 playerBarData.value = ... 都没有任何东西拦他。
#
# 现在把"写入口只许有几处"变成结构约束:
#   · 槽位清单**自动发现**: ui/lib/src 里所有顶格(库级)声明的
#     final ValueNotifier<...> name = ... 都算槽位, 新增一个就自动纳入本门,
#     不需要回来改脚本;
#   · 允许写入的文件 = 该槽位的**声明文件**(owner: 槽位本体 + 它的受控入口, 如
#     detail_pane.dart 的 closeDetailPane/openDetail、stream_note.dart 的
#     publishStreamNote、app_shell.dart 的 publish*)
#     + ui/lib/src/home/home_wiring.dart(壳层装配: 注册/清理动作宿主与播放条回调,
#     两处都已帧后投递)。
#   · 别的文件里出现 name.value = 就是违规: 改成调用 owner 暴露的入口。
#
# 已知例外(注释说明, 不修):
#   · ui/lib/src/detail_pane.dart 的 DetailPaneSplit.build: 窗口从宽档缩到窄/中档时
#     用裸 WidgetsBinding.instance.addPostFrameCallback 帧后调 closeDetailPane()。
#     这一处**故意不加存活守卫** —— 清右栏是幂等的全局收尾, 恰好是"页面没了也必须
#     清"(否则下次进首页会看到上一条残留的右栏), 与 runPostFrameIfAlive 的
#     "页面没了就别写"语义相反。写入本身仍走受控入口 closeDetailPane。
#
# 口径与 tools/check-sheet-entry.sh 一致: 扫描 ui/lib/src(生产代码); ui/test/**
# 不在范围(测试要直接摆槽位初值/断言)。整行注释(`//` / `///` 开头)不算命中 ——
# 文档里引用 x.value = y 当反例是常态, 只有真实赋值语句才拦。
#
# 用法:
#   tools/check-global-slots.sh             # 门禁模式: 有违规退出 1
#   tools/check-global-slots.sh --self-test # 负向自测: 临时插一处直写, 断言报红
set -uo pipefail
cd "$(dirname "$0")/.."

self_test=0
for arg in "$@"; do
  case "$arg" in
    --self-test) self_test=1 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

LIB="ui/lib/src"

# 槽位的声明文件 + 壳层装配文件(槽位换文件时这里自动跟着变)。
OWNER_FILES=$(rg -l --no-heading -e '^final ValueNotifier' "$LIB" 2>/dev/null || true)
if [ -z "$OWNER_FILES" ]; then
  echo "::error::没发现任何顶格 ValueNotifier —— 正则或目录写错了(本门会假绿)"
  exit 1
fi
ALLOW_FILES="$OWNER_FILES
ui/lib/src/home/home_wiring.dart"

# 槽位名: 顶格 final ValueNotifier<...> name = 里的 name(泛型可能含空格与嵌套 >)
slot_names() {
  rg -N --no-filename -e '^final ValueNotifier' "$LIB" 2>/dev/null \
    | sed -n 's/^final[[:space:]]\{1,\}ValueNotifier.*>[[:space:]]\{1,\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*.*$/\1/p' \
    | sort -u
}

SLOTS=$(slot_names)
if [ -z "$SLOTS" ]; then
  echo "::error::解析不出槽位名(顶格 ValueNotifier 的声明格式变了?)"
  exit 1
fi
SLOT_RE=$(printf '%s\n' "$SLOTS" | paste -sd'|' -)
# 赋值而不是比较: .value = x 命中, .value == x 不命中。
PATTERN="\b($SLOT_RE)\.value[[:space:]]*=[^=]"

# 允许清单 → 正则(路径里的 . 要转义; 每行锚到行首并以 : 结束, 匹配 rg 的 path:line)。
allow_re=$(printf '%s\n' "$ALLOW_FILES" | sed 's/[.]/\\./g' | paste -sd'|' -)
ALLOW="^($allow_re):"

scan() {
  rg -n --no-heading -e "$PATTERN" "$LIB" 2>/dev/null \
    | grep -Ev '^.*:[0-9]+:[[:space:]]*//' \
    | grep -Ev "$ALLOW" || true
}

count() { printf '%s\n' "$SLOTS" | wc -l | tr -d ' '; }

if [ "$self_test" = 1 ]; then
  tmp="$LIB/_global_slots_selftest_tmp.dart"
  trap 'rm -f "$tmp"' EXIT
  # 临时文件不是任何槽位的声明文件 ⇒ 这处直写必须被抓到。
  cat > "$tmp" <<'DART'
// check-global-slots.sh --self-test 的临时文件(退出时自动删除)
// ignore_for_file: unused_import
import 'now_playing.dart';

void selftestSlotWrite() {
  nowPlayingSongId.value = null;
}
DART
  if [ -n "$(scan)" ]; then
    echo "OK: self-test 生效(临时文件里的槽位直写被抓到)"
    exit 0
  fi
  echo "::error::self-test 失败 —— 插进去的槽位直写没被抓到(正则或允许清单写错了)"
  exit 1
fi

violations=$(scan)

if [ -n "$violations" ]; then
  echo "::error::全局槽位直写(必须走声明方暴露的 publish* 入口):"
  echo "$violations"
  echo
  echo "  槽位(自动发现, 共 $(count) 个): $(printf '%s ' $SLOTS)"
  echo "  允许写入的文件(槽位声明方 + home_wiring):"
  printf '    %s\n' $ALLOW_FILES
  echo
  echo "  典型改法:"
  echo "    playerBarData.value = data                 # 不要"
  echo "    publishPlayerBarSnapshot(context, data: data, nowPlayingId: id)"
  echo "    actionsHost.value = host                   # 不要"
  echo "    publishActionsHost(context, host)"
  echo "    新槽位就在它声明的地方加一个 runPostFrameIfAlive 包装的 publish* 入口"
  exit 1
fi

echo "OK: ui/lib/src 的全局槽位写入只在声明方与 home_wiring 里($(count) 个槽位)"
