import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/category_bar.dart';
import 'package:minincm/src/layout.dart';

/// 分类条回归(2026-11-14 用户四轮反馈后的最终口径):
/// 「搜索结果的分类」与「输入联想的分类」共用 [CategoryBar], **永远只有一横排**,
/// 放不下时靠用户横向拖拽 —— 不换行, 于是"末尾空缺/两排对齐/被拉伸"这些排版问题
/// 在结构上就不存在了。
///
/// 这里钉住三件事:
/// ① 所有 chip 同一行(y 相同), 左边界递增, 第一个贴页面留白;
/// ② 一屏放不下时可以横向拖动, 拖到底能看到最后一个分类;
/// ③ 切换选中不改变任何 chip 的位置/宽度(没有 checkmark 撑宽)。
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

  testWidgets('永远只有一横排: 所有 chip 同一行且从页面左边距开始', (tester) async {
    useNarrowScreen(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // 与搜索结果页一致: Column 默认 center(曾经导致"居中缩进"的触发条件)
          body: Column(
            children: [
              CategoryBar(labels: labels, selected: 0, onSelected: (_) {}),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final rects = chipRects(tester);
    expect(rects.length, labels.length);
    for (final rect in rects) {
      expect(rect.top, closeTo(rects.first.top, 0.5), reason: '必须排在同一横排');
      expect(rect.height, closeTo(rects.first.height, 0.5));
    }
    expect(rects.first.left, closeTo(kPagePadding, 0.5));
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThan(rects[i - 1].right));
    }
  });

  testWidgets('一屏放不下时可横向拖拽, 拖到底能看到最后一个分类', (tester) async {
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
    await tester.pump();
    final before = chipRects(tester).last;
    expect(
      before.right,
      greaterThan(400),
      reason: '400dp 放不下 7 个 chip, 最后一个应在屏外(靠拖拽看到)',
    );

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    final after = chipRects(tester).last;
    expect(
      after.right,
      lessThanOrEqualTo(400.5),
      reason: '拖到底后最后一个 chip 应完整可见',
    );
    expect(after.left, greaterThanOrEqualTo(-0.5));
  });

  testWidgets('切换选中的分类不改变任何 chip 的位置/宽度', (tester) async {
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
    await tester.pump();
    final before = chipRects(tester);

    await tester.tap(find.text('用户'));
    await tester.pump();
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
