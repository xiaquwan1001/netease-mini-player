import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/category_bar.dart';
import 'package:minincm/src/layout.dart';

/// 回归 2026-11-14 用户反馈 1/2:
/// 「搜索页面的分类前面有奇怪的缩进, 没有对齐, 也没利用显示宽度」
/// 「当且仅当聚焦 tab 是第二排(用户/MV)时, 两排分类又突然对齐了, 缩进消失」
///
/// 根因有两个, 这里都钉成断言:
/// ① 分类条以前是 `Padding + Wrap`, 在 `Column`(crossAxisAlignment.center) 的松约束下
///    收缩到内容宽度后被**居中**, 于是左边界随行宽漂移(选中排的宽度一变就跳);
/// ② 选中项默认带 checkmark, chip 变宽 ⇒ 一次切换就让整条重新排版。
void main() {
  const labels = ['单曲', '艺人', '专辑', '歌单', '播客', '用户', 'MV'];

  void useNarrowScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  List<Rect> chipRects(WidgetTester tester) {
    final finder = find.byType(ChoiceChip);
    return [
      for (var i = 0; i < finder.evaluate().length; i++)
        tester.getRect(finder.at(i)),
    ];
  }

  testWidgets('分类条两排都贴齐页面左边距, 不被 Column 居中', (tester) async {
    useNarrowScreen(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 与搜索结果页一致: Column 默认 center, 正是"居中缩进"的触发条件
          body: Column(
            children: [
              CategoryBar(labels: labels, selected: 0, onSelected: (_) {}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rects = chipRects(tester);
    expect(rects.length, labels.length);
    // 真的排成了两排(400dp 宽放不下 7 个 chip)
    final firstRowTop = rects.first.top;
    final secondRow = rects.where((r) => r.top > firstRowTop + 1).toList();
    expect(secondRow, isNotEmpty, reason: '400dp 宽应换行');
    // 每一排的第一个 chip 都贴页面留白, 不该出现"被居中的缩进"
    expect(rects.first.left, closeTo(kPagePadding, 0.5));
    expect(secondRow.first.left, closeTo(kPagePadding, 0.5));
  });

  testWidgets('选中第二排的分类不改变任何 chip 的位置/宽度(缩进不消失也不漂移)', (tester) async {
    useNarrowScreen(tester);
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                CategoryBar(
                  labels: labels,
                  selected: selected,
                  onSelected: (i) => setState(() => selected = i),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = chipRects(tester);

    // 点第二排的「用户」
    await tester.tap(find.text('用户'));
    await tester.pumpAndSettle();
    final after = chipRects(tester);

    expect(selected, 5);
    for (var i = 0; i < before.length; i++) {
      expect(
        after[i].left,
        closeTo(before[i].left, 0.01),
        reason: 'chip $i 左边界不应漂移',
      );
      expect(
        after[i].width,
        closeTo(before[i].width, 0.01),
        reason: 'chip $i 宽度不应随选中变化(没有 checkmark)',
      );
    }
  });

  testWidgets('每排都铺满整行宽度: 末尾不再留空缺', (tester) async {
    useNarrowScreen(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CategoryBar(labels: labels, selected: 0, onSelected: (_) {}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rects = chipRects(tester);
    expect(rects.length, labels.length);

    // 按 top 分组(同一排 y 相同), 每排两端都必须贴页面留白
    final rows = <double, List<Rect>>{};
    for (final rect in rects) {
      final key = rows.keys.firstWhere(
        (top) => (top - rect.top).abs() < 1,
        orElse: () => rect.top,
      );
      rows.putIfAbsent(key, () => <Rect>[]).add(rect);
    }
    const pageRight = 400 - kPagePadding;
    for (final row in rows.values) {
      row.sort((a, b) => a.left.compareTo(b.left));
      expect(
        row.first.left,
        closeTo(kPagePadding, 0.5),
        reason: '每排第一个 chip 贴左边距',
      );
      expect(
        row.last.right,
        closeTo(pageRight, 0.5),
        reason: '每排最后一个 chip 必须贴右边距(末尾没有空缺)',
      );
      // 同一排等宽且相邻间隔固定
      for (var i = 1; i < row.length; i++) {
        expect(row[i].width, closeTo(row.first.width, 0.01));
        expect(row[i].left - row[i - 1].right, closeTo(6, 0.01));
      }
    }
    // 7 个分类在 400dp 下是两排, 且均分成 4+3(不是 6+1)
    expect(rows.length, 2);
    expect(rows.values.map((r) => r.length).toList()..sort(), [3, 4]);
  });

  testWidgets('带条数时 chip 文案包含数量', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              CategoryBar(
                labels: const ['单曲', '艺人'],
                selected: 0,
                onSelected: (_) {},
                counts: const [4, 1],
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('单曲 4'), findsOneWidget);
    expect(find.text('艺人 1'), findsOneWidget);
  });
}
