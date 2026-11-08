import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';

/// 顶部栏只承载导航里没有的信息(2026-11-09 用户要求: 去掉与底部导航重复的关键词,
/// 并去掉搜索页顶部的「轻音 MiniNCM」横幅, 把高度让给内容)。
///
/// 规则:
/// - 五个 tab 的首页都**没有** AppBar;
/// - 歌词展开 / 歌单浏览态才有顶部栏(曲名·列表名 + 收起·返回按钮)。
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

  testWidgets('搜索页没有「轻音 MiniNCM」横幅(无 AppBar)', (tester) async {
    await pumpHome(tester);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('轻音 MiniNCM'), findsNothing);
    // 搜索框自身也有"搜索"字样, 这里只保证顶部不再有重复的标题区(无 AppBar 即无标题)
    expect(
      find.descendant(of: find.byType(NavigationBar), matching: find.text('搜索')),
      findsOneWidget,
    );
  });

  testWidgets('推荐/关注/我的/设置 tab 都没有顶部栏, 关键词只在导航出现一次', (tester) async {
    await pumpHome(tester);
    for (final label in ['推荐', '关注', '我的', '设置']) {
      await tester.tap(find.text(label));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.byType(AppBar), findsNothing, reason: '$label tab 不该有顶部栏');
      expect(find.text(label), findsOneWidget, reason: '$label 只应出现在底部导航里');
    }
  });
}
