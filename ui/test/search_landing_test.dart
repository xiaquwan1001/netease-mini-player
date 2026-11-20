import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
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
          recommended: const [RecommendedKeyword(keyword: '周杰伦')],
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
              recommended: const [RecommendedKeyword(keyword: '周杰伦')],
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
          recommended: const [],
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
          recommended: const [],
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
          recommended: const [],
          onSelected: (_) {},
          onClearHistory: () {},
        ),
      ),
    );
    expect(find.text('暂无热词'), findsOneWidget);
    expect(find.text('搜索历史'), findsNothing);
  });

  // ---- 「猜你想搜」2026-11 改版: 多个候选 + 格子 + 会更新 ----

  testWidgets('多个候选渲染成与历史一致的 chip 格子, 点谁搜谁', (tester) async {
    String? chosen;
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const ['七里香'],
          hot: const [],
          recommended: const [
            RecommendedKeyword(keyword: '周杰伦'),
            RecommendedKeyword(keyword: '稻香'),
            RecommendedKeyword(keyword: '夜曲'),
          ],
          onSelected: (k) => chosen = k,
          onClearHistory: () {},
        ),
      ),
    );

    expect(find.text('猜你想搜'), findsOneWidget);
    final chips = find.byType(ActionChip);
    // 1 条历史 + 3 个候选, 全是同一套 ActionChip
    expect(chips, findsNWidgets(4));
    expect(find.widgetWithText(ActionChip, '周杰伦'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '稻香'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '夜曲'), findsOneWidget);
    // 不再是一张整行 Card+ListTile
    expect(find.byType(ListTile), findsNothing);

    // 命中区与历史 chip 同一口径(≥48dp)
    for (final keyword in ['周杰伦', '稻香', '夜曲']) {
      final size = tester.getSize(find.widgetWithText(ActionChip, keyword));
      expect(size.height, greaterThanOrEqualTo(48), reason: keyword);
    }

    await tester.tap(find.text('稻香'));
    expect(chosen, '稻香');
  });

  testWidgets('候选上限 4: 传再多也只渲染 4 个格子', (tester) async {
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const [],
          hot: const [],
          recommended: const [
            RecommendedKeyword(keyword: '候选一'),
            RecommendedKeyword(keyword: '候选二'),
            RecommendedKeyword(keyword: '候选三'),
            RecommendedKeyword(keyword: '候选四'),
            RecommendedKeyword(keyword: '候选五'),
            RecommendedKeyword(keyword: '候选六'),
          ],
          onSelected: (_) {},
          onClearHistory: () {},
        ),
      ),
    );

    expect(find.byType(ActionChip), findsNWidgets(4));
    expect(find.text('候选四'), findsOneWidget);
    expect(find.text('候选五'), findsNothing);
    expect(find.text('候选六'), findsNothing);
  });

  testWidgets('空候选: 连「猜你想搜」标题一起不渲染', (tester) async {
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const ['七里香'],
          hot: const [],
          recommended: const [],
          onSelected: (_) {},
          onClearHistory: () {},
        ),
      ),
    );
    expect(find.text('猜你想搜'), findsNothing);
    expect(find.byType(ActionChip), findsOneWidget); // 只剩历史那一个
  });

  testWidgets('推荐理由只做 Tooltip, 不占行', (tester) async {
    await tester.pumpWidget(
      host(
        SearchLanding(
          history: const [],
          hot: const [],
          recommended: const [
            RecommendedKeyword(keyword: 'Mili', reason: '🔥Mili 你的十月榜首'),
            RecommendedKeyword(keyword: '稻香'),
          ],
          onSelected: (_) {},
          onClearHistory: () {},
        ),
      ),
    );

    // 理由文案不直接铺在页面上
    expect(find.text('🔥Mili 你的十月榜首'), findsNothing);
    final tips = tester.widgetList<Tooltip>(find.byType(Tooltip));
    expect(
      tips.map((t) => t.message),
      contains('🔥Mili 你的十月榜首'),
      reason: '有理由的候选要能长按看到来源说明',
    );
    // 没理由的候选不加空 Tooltip
    expect(tips.map((t) => t.message), isNot(contains('')));
  });

  testWidgets('换成新候选集合会替换旧内容(「有新的就换」)', (tester) async {
    Widget page(List<RecommendedKeyword> items) => host(
      SearchLanding(
        history: const ['七里香'],
        hot: const [],
        recommended: items,
        onSelected: (_) {},
        onClearHistory: () {},
      ),
    );

    await tester.pumpWidget(
      page(const [
        RecommendedKeyword(keyword: '旧候选甲'),
        RecommendedKeyword(keyword: '旧候选乙'),
      ]),
    );
    expect(find.text('旧候选甲'), findsOneWidget);

    await tester.pumpWidget(
      page(const [
        RecommendedKeyword(keyword: '新候选甲'),
        RecommendedKeyword(keyword: '新候选乙'),
      ]),
    );
    expect(find.text('旧候选甲'), findsNothing);
    expect(find.text('旧候选乙'), findsNothing);
    expect(find.text('新候选甲'), findsOneWidget);
    expect(find.text('新候选乙'), findsOneWidget);
  });
}
