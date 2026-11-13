import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_landing.dart';

rust.HotSearchTerm hot(int rank, String keyword) =>
    rust.HotSearchTerm(rank: rank, keyword: keyword);

rust.ChartSummary chart(int id, String name) => rust.ChartSummary(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  updateFrequency: '刚刚更新',
  trackCount: BigInt.from(100),
  playCount: BigInt.from(1000),
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('搜索落地页展示历史/猜你想搜/带名次的热门', (tester) async {
    String? chosen;
    var cleared = 0;
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const ['七里香'],
          hot: [hot(1, '晴天'), hot(2, '稻香')],
          recommended: '周杰伦',
          onSelected: (k) => chosen = k,
          onClearHistory: () => cleared++,
        ),
      ),
    );

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
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, '清空'),
      ),
    );
    await tester.pumpAndSettle();
    expect(cleared, 1);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: SearchLanding(
              history: const ['七里香', '一条很长很长的搜索历史关键词用于小屏回归测试'],
              hot: [hot(1, '晴天'), hot(2, '稻香')],
              recommended: '周杰伦',
              onSelected: (_) {},
              onClearHistory: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('热门搜索'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
  });

  testWidgets('热词加载失败显示重试', (tester) async {
    var retried = 0;
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const [],
          hot: const [],
          recommended: null,
          onSelected: (_) {},
          onClearHistory: () {},
          hotError: '网络不稳定',
          onRetryHot: () => retried++,
        ),
      ),
    );
    expect(find.textContaining('热词获取失败'), findsOneWidget);
    await tester.tap(find.text('重试'));
    expect(retried, 1);
  });

  testWidgets('排行榜区块: 从推荐页搬来, 点榜单打开歌单', (tester) async {
    rust.Playlist? opened;
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const [],
          hot: const [],
          recommended: null,
          onSelected: (_) {},
          onClearHistory: () {},
          loadCharts: () async => [
            chart(19723756, '飙升榜'),
            chart(3779629, '新歌榜'),
          ],
          onOpenChartPlaylist: (p) => opened = p,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.text('新歌榜'), findsOneWidget);
    expect(find.text('全部'), findsOneWidget);

    await tester.tap(find.text('飙升榜'));
    expect(opened?.id, BigInt.from(19723756));
  });

  testWidgets('无热词且不在加载时显示空态', (tester) async {
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const [],
          hot: const [],
          recommended: null,
          onSelected: (_) {},
          onClearHistory: () {},
        ),
      ),
    );
    expect(find.text('暂无热词'), findsOneWidget);
    expect(find.text('搜索历史'), findsNothing);
  });
}
