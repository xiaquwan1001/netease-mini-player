import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/recent_order.dart';

/// 纯函数用例: 只钉"最近交互优先"的口径, 不搭 widget 树
/// (widget 层的区块换位见 mine_view_test.dart)。

class Item {
  Item(this.id, this.name);

  final int id;
  final String name;

  BigInt get bigId => BigInt.from(id);
}

Item item(int id) => Item(id, 'item$id');

List<String> names(List<Item> items) => [for (final i in items) i.name];

/// 交互记录表: id -> epoch ms
int? Function(BigInt) rec(Map<int, int> map) =>
    (id) => map[id.toInt()];

void main() {
  test('无任何交互记录时保持后端原顺序', () {
    final items = [item(1), item(2), item(3)];
    final sorted = sortByRecentInteraction(items, (i) => i.bigId, rec({}));
    expect(names(sorted), ['item1', 'item2', 'item3']);
  });

  test('有交互记录的按时间倒序排在前面', () {
    final items = [item(1), item(2), item(3)];
    final sorted = sortByRecentInteraction(
      items,
      (i) => i.bigId,
      rec({1: 100, 2: 300, 3: 200}),
    );
    expect(names(sorted), ['item2', 'item3', 'item1']);
  });

  test('无记录的条目排在最后, 且它们之间保持原顺序', () {
    final items = [item(1), item(2), item(3), item(4)];
    final sorted = sortByRecentInteraction(items, (i) => i.bigId, rec({3: 50}));
    expect(names(sorted), ['item3', 'item1', 'item2', 'item4']);
  });

  test('时间戳相同时保持原顺序(List.sort 本身不稳定, 这里要显式兜底)', () {
    final items = [item(1), item(2), item(3), item(4)];
    final sorted = sortByRecentInteraction(
      items,
      (i) => i.bigId,
      rec({1: 500, 2: 500, 3: 500}),
    );
    expect(names(sorted), ['item1', 'item2', 'item3', 'item4']);
  });

  test('不修改入参列表(纯函数)', () {
    final items = [item(1), item(2)];
    sortByRecentInteraction(items, (i) => i.bigId, rec({2: 999}));
    expect(names(items), ['item1', 'item2']);
  });

  test('compareSectionsByRecent: 大者在前, null 视为 -1(从未交互)', () {
    expect(compareSectionsByRecent(200, 100), greaterThan(0));
    expect(compareSectionsByRecent(100, 200), lessThan(0));
    expect(compareSectionsByRecent(null, 1), lessThan(0));
    expect(compareSectionsByRecent(1, null), greaterThan(0));
    // 都没有记录 / 时间戳持平 ⇒ 相等, 由调用方退回默认顺序(专辑优先)
    expect(compareSectionsByRecent(null, null), 0);
    expect(compareSectionsByRecent(7, 7), 0);
  });

  test('latestInteractionMs: 取栏目内最新一条, 无记录/空数据为 null', () {
    final items = [item(1), item(2), item(3)];
    expect(latestInteractionMs(items, (i) => i.bigId, rec({1: 10, 3: 40})), 40);
    expect(latestInteractionMs(items, (i) => i.bigId, rec({})), isNull);
    expect(latestInteractionMs(<Item>[], (i) => i.bigId, rec({1: 1})), isNull);
    expect(
      latestInteractionMs<Item>(null, (i) => i.bigId, rec({1: 1})),
      isNull,
    );
  });
}
