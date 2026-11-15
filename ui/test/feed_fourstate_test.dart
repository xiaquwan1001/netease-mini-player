// 关注动态流四态收口(AsyncView)回归:
// 首屏失败整块错误 + 重试只取一次 / 刷新失败保留已加载内容 / 空列表刷新拿到内容
// 后不再停在空态(AsyncView 的空态判定必须跟到最新列表实例)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.FeedEventDto event(int id) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_1',
  userId: BigInt.from(10),
  kind: 'text',
  userName: '艺人甲',
  text: '动态 $id',
  title: '',
  images: const [],
  timeMs: BigInt.from(1700000000000 - id * 1000),
  liked: false,
  likedCount: BigInt.zero,
  shareCount: BigInt.zero,
  commentCount: BigInt.zero,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 顶部下拉触发刷新(列表已在顶部, 直接甩下去)
Future<void> pullToRefresh(WidgetTester tester) async {
  final list = find.byType(ListView).last;
  await tester.fling(list, const Offset(0, 400), 1000);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('首屏加载失败: 整块错误 + 重试只重取一次', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async {
            loads++;
            // 非网络错: 不触发 retryNetwork 的退避重试, 测试里不会留 pending timer
            if (loads == 1) throw Exception('[internal] boom');
            return [event(1)];
          },
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(find.textContaining('boom'), findsOneWidget, reason: '文案走 friendlyError');
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(loads, 2, reason: '一次重试只触发一次取数');
    expect(find.text('动态 1'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('下拉刷新失败: 保留已加载列表, 只提示不整页报错', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async {
            loads++;
            if (loads > 1) throw Exception('[internal] boom');
            return [for (var i = 1; i <= 5; i++) event(i)];
          },
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('动态 1'), findsOneWidget);

    await pullToRefresh(tester);
    expect(loads, 2);
    // 已渲染的列表不因刷新失败消失, 也不打整页错误
    expect(find.text('动态 1'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    expect(find.textContaining('刷新失败'), findsOneWidget, reason: '失败只弹提示');
    // 让提示条走完, 不留 pending timer
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('空列表下拉刷新拿到内容后不再停在空态', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async {
            loads++;
            return loads == 1 ? const <rust.FeedEventDto>[] : [event(1)];
          },
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有动态'), findsOneWidget);

    await pullToRefresh(tester);
    expect(loads, 2);
    expect(find.text('还没有动态'), findsNothing, reason: '空态判定要跟到刷新后的列表');
    expect(find.text('动态 1'), findsOneWidget);
  });
}
