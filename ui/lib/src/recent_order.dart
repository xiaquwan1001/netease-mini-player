// 「我的」页的"最近有交互的优先展示"排序, 纯函数, 单测见
// `test/recent_order_test.dart`。
//
// 口径(用户 2026-11 需求原话: 收藏的专辑放到收藏的播客前, 且两个栏目的顺序是
// 最近有交互的优先展示):
// - 栏目内条目: 按"最近一次交互"(打开/播放该条目)倒序; 没有交互记录的条目
//   保持后端返回的原顺序排在最后(后端顺序当次键, 否则每次进页面次序都会抖)。
// - 栏目之间: 取各自栏目内最新一条的时间戳比较, 大者在前; 两边都没有记录
//   (或时间戳相同)时按默认顺序 —— 收藏专辑 → 收藏播客, 由调用方决定默认次序。
//
// 为什么单独抽成纯函数: 排序规则要能被单测直接钉住, 不必搭 widget 树;
// 「我的」页只负责把数据与时间戳喂进来。

/// 按最近交互倒序排列; 无记录保持原顺序排在最后.
///
/// [idOf] 取条目 id, [lastMsOf] 返回该 id 最近一次交互的 epoch ms(null = 无记录)。
/// 时间戳相同的条目也保持原顺序(Dart 的 List.sort 不保证稳定, 这里显式用下标兜底)。
List<T> sortByRecentInteraction<T>(
  List<T> items,
  BigInt Function(T) idOf,
  int? Function(BigInt) lastMsOf,
) {
  final entries = <({int index, int? ms, T item})>[
    for (var i = 0; i < items.length; i++)
      (index: i, ms: lastMsOf(idOf(items[i])), item: items[i]),
  ];
  entries.sort((a, b) {
    final am = a.ms;
    final bm = b.ms;
    // 无记录一律靠后; 两者都无记录时退还原顺序
    if (am == null && bm == null) return a.index - b.index;
    if (am == null) return 1;
    if (bm == null) return -1;
    final byMs = bm.compareTo(am);
    return byMs != 0 ? byMs : a.index - b.index;
  });
  return [for (final e in entries) e.item];
}

/// 一段数据里最新的交互时间(栏目之间比较用); 全都没有记录时返回 null.
int? latestInteractionMs<T>(
  List<T>? items,
  BigInt Function(T) idOf,
  int? Function(BigInt) lastMsOf,
) {
  if (items == null) return null;
  int? latest;
  for (final item in items) {
    final ms = lastMsOf(idOf(item));
    if (ms == null) continue;
    if (latest == null || ms > latest) latest = ms;
  }
  return latest;
}

/// 比较两个 section 谁在前(大者在前, null 视为 -1 = 从未交互).
///
/// 返回值语义同 [Comparator]: >0 表示 a 应排在 b 前面,
/// == 0 表示两边一样新 —— 调用方按默认顺序处理(专辑优先)。
int compareSectionsByRecent(int? a, int? b) => (a ?? -1).compareTo(b ?? -1);
