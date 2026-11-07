import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_landing.dart';

rust.HotSearchTermDto hot(int rank, String keyword) =>
    rust.HotSearchTermDto(rank: rank, keyword: keyword);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('搜索落地页展示历史/猜你想搜/带名次的热门', (tester) async {
    String? chosen;
    var cleared = 0;
    await tester.pumpWidget(host(SearchLanding(
      history: const ['七里香'],
      hot: [hot(1, '晴天'), hot(2, '稻香')],
      recommended: '周杰伦',
      onSelected: (k) => chosen = k,
      onClearHistory: () => cleared++,
    )));

    expect(find.text('搜索历史'), findsOneWidget);
    expect(find.text('猜你想搜'), findsOneWidget);
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.text('稻香'));
    expect(chosen, '稻香');

    await tester.tap(find.text('周杰伦'));
    expect(chosen, '周杰伦');

    // C2: 清空需二次确认 —— 先弹确认框, 取消不清, 确认才清
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('清空搜索历史'), findsOneWidget);
    expect(cleared, 0, reason: '弹确认框时不应立刻清空');

    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(cleared, 0, reason: '取消后不清空');

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '清空'),
    ));
    await tester.pumpAndSettle();
    expect(cleared, 1);
  });

  testWidgets('热词加载失败显示重试', (tester) async {
    var retried = 0;
    await tester.pumpWidget(host(SearchLanding(
      history: const [],
      hot: const [],
      recommended: null,
      onSelected: (_) {},
      onClearHistory: () {},
      hotError: '网络不稳定',
      onRetryHot: () => retried++,
    )));
    expect(find.textContaining('热词获取失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, 1);
  });

  testWidgets('无热词且不在加载时显示空态', (tester) async {
    await tester.pumpWidget(host(SearchLanding(
      history: const [],
      hot: const [],
      recommended: null,
      onSelected: (_) {},
      onClearHistory: () {},
    )));
    expect(find.text('暂无热词'), findsOneWidget);
    expect(find.text('搜索历史'), findsNothing);
  });
}
