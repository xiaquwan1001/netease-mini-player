import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';

/// 顶部栏不再重复底部导航的关键词(2026-11-09 用户要求"更多空间留给内容")。
///
/// 规则:
/// - 首 tab(搜索): 顶部显示品牌名/歌单名 —— 与导航标签"搜索"不重复, 保留;
/// - 推荐/关注/我的/设置: 原标题就是导航标签本身 ⇒ 整条 AppBar 不出现, 56dp 让给内容。
void main() {
  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    addTearDown(() async {
      try {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      } catch (_) {}
    });
  }

  testWidgets('首 tab 有顶部栏(品牌名), 且不与导航标签重复', (tester) async {
    await pumpHome(tester);
    expect(find.byType(AppBar), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('轻音 MiniNCM')),
      findsOneWidget,
    );
    // 顶部不该出现"搜索"(那是底部导航的标签)
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('搜索')),
      findsNothing,
    );
  });

  testWidgets('推荐/关注/我的/设置 tab 都没有顶部栏', (tester) async {
    await pumpHome(tester);
    for (final label in ['推荐', '关注', '我的', '设置']) {
      await tester.tap(find.text(label).last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.byType(AppBar), findsNothing, reason: '$label tab 不该有顶部栏');
      // 该 tab 的关键词只在底部导航里出现一次(不再有顶部标题复制一份)
      expect(find.text(label), findsOneWidget, reason: '$label 只应出现在底部导航里');
    }
  });
}
