import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/feed/feed_view_body.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// 关注页选中艺人后的"贪婪加载历史"回归(用户反馈 2026-11-19, 发条月亮):
///
/// 关注流只有最近一页, 某个艺人往往只出现 1 条; 选中艺人后必须把数据源切到
/// 该艺人自己的 userEvents(uid, limit, lastTime), 按 lastTime 一直往前翻,
/// 下拉刷新重取最新一页并与历史按 id 合并(不能把历史刷没)。

/// 时间从新到旧: id 越大越早(与真实接口一致)
rust.FeedEventDto event(
  int id, {
  int userId = 10,
  String name = '艺人甲',
  String? text,
}) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_1',
  userId: BigInt.from(userId),
  kind: 'text',
  userName: name,
  avatarUrl: null,
  text: text ?? '动态 $id',
  song: null,
  coverUrl: null,
  images: const [],
  videoUrl: null,
  title: '',
  timeMs: BigInt.from(1700000000000 - id * 1000),
  liked: false,
  likedCount: BigInt.zero,
  shareCount: BigInt.zero,
  commentCount: BigInt.zero,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 点横条上的 chip(私有组件, 用 runtimeType 名匹配; 见 feed_author_strip_test)
Future<void> tapChip(WidgetTester tester, String label) async {
  final chip = find.byWidgetPredicate(
    (w) => '${w.runtimeType}' == '_AuthorChip',
  );
  final target = find.descendant(of: chip, matching: find.text(label));
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

/// 反复上滑直到 [stop] 为 true 或达到上限(不用 pumpAndSettle:
/// footer 的加载圈是持续动画, settle 会超时)
Future<void> dragToBottom(
  WidgetTester tester, {
  required bool Function() stop,
  int rounds = 40,
}) async {
  final list = find.byType(ListView).last;
  for (var i = 0; i < rounds && !stop(); i++) {
    await tester.drag(list, const Offset(0, -400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  testWidgets('选中艺人后切到 ta 自己的动态流(uid 正确, 不再只靠关注页过滤)', (tester) async {
    final calls = <({BigInt uid, int lastTime})>[];
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(1, userId: 10, name: '艺人甲'),
            event(2, userId: 20, name: '艺人乙'),
          ],
          loadSubscribedArtists: () async => const [],
          loadArtistEvents:
              ({
                required BigInt uid,
                required int limit,
                required int lastTime,
              }) async {
                calls.add((uid: uid, lastTime: lastTime));
                return [
                  event(101, userId: 20, name: '艺人乙', text: '艺人乙的历史1'),
                  event(102, userId: 20, name: '艺人乙', text: '艺人乙的历史2'),
                ];
              },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await tapChip(tester, '艺人乙');
    expect(calls.length, 1);
    expect(calls.first.uid, BigInt.from(20));
    expect(calls.first.lastTime, -1, reason: '首屏 = 最新一页');

    // 数据源换了: 看到的是该艺人的历史动态, 关注页的其它条目不在
    expect(find.text('艺人乙的历史1'), findsOneWidget);
    expect(find.text('艺人乙的历史2'), findsOneWidget);
    expect(find.text('动态 1'), findsNothing);
  });

  testWidgets('滚到底用该艺人最后一条 time_ms 拉更早一页并合并去重', (tester) async {
    final calls = <int>[];
    // 首屏 30 条(满页)才会继续翻; 第二页与首屏最后一条重复, 新增 31..34
    final first = [
      for (var i = 1; i <= 30; i++) event(i, userId: 20, name: '艺人乙'),
    ];
    final older = [
      event(30, userId: 20, name: '艺人乙'),
      for (var i = 31; i <= 34; i++) event(i, userId: 20, name: '艺人乙'),
    ];

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(0, userId: 20, name: '艺人乙'),
            event(1, userId: 10, name: '艺人甲'),
          ],
          loadSubscribedArtists: () async => const [],
          loadArtistEvents:
              ({
                required BigInt uid,
                required int limit,
                required int lastTime,
              }) async {
                calls.add(lastTime);
                if (lastTime == -1) return first;
                return older;
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tapChip(tester, '艺人乙');
    expect(calls, [-1]);

    await dragToBottom(tester, stop: () => calls.length > 1);
    expect(calls.length, 2);
    expect(
      calls[1],
      1700000000000 - 30 * 1000,
      reason: '游标 = 已加载列表最后一条(id 30)的 time_ms',
    );

    await tester.pumpAndSettle();
    await dragToBottom(
      tester,
      stop: () => find.text('动态 34').evaluate().isNotEmpty,
    );
    expect(find.text('动态 34'), findsOneWidget);
    // 重复 id 30 只保留一条(合并去重)
    expect(find.text('动态 30'), findsOneWidget);
    // 第二页不满 ⇒ 不再继续请求
    expect(calls.length, 2);
  });

  testWidgets('下拉刷新重取最新一页: 新条目插前, 已加载历史不丢', (tester) async {
    final calls = <int>[];
    var round = 0;
    final first = [
      for (var i = 1; i <= 30; i++) event(i, userId: 20, name: '艺人乙'),
    ];

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(0, userId: 20, name: '艺人乙'),
            event(1, userId: 10, name: '艺人甲'),
          ],
          loadSubscribedArtists: () async => const [],
          loadArtistEvents:
              ({
                required BigInt uid,
                required int limit,
                required int lastTime,
              }) async {
                calls.add(lastTime);
                if (lastTime != -1) {
                  // 历史页: 31..34
                  return [
                    for (var i = 31; i <= 34; i++)
                      event(i, userId: 20, name: '艺人乙'),
                  ];
                }
                round++;
                if (round == 1) return first;
                // 刷新后的最新页: 新动态 id 0 + 首屏第一条(id 1)的新副本
                return [
                  event(0, userId: 20, name: '艺人乙', text: '刷新出来的新动态'),
                  event(1, userId: 20, name: '艺人乙'),
                ];
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tapChip(tester, '艺人乙');
    // 先滚到底把历史翻出来(懒构建: 新追加的条目要滚到才会建出来)
    await dragToBottom(tester, stop: () => calls.length > 1);
    await dragToBottom(
      tester,
      stop: () => find.text('动态 34').evaluate().isNotEmpty,
    );
    expect(find.text('动态 34'), findsOneWidget);

    // 回顶部并下拉刷新
    final list = find.byType(ListView).last;
    await tester.drag(list, const Offset(0, 4000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.fling(list, const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(calls.where((t) => t == -1).length, 2, reason: '刷新重取最新一页');
    expect(find.text('刷新出来的新动态'), findsOneWidget);
    // 历史仍在
    await dragToBottom(
      tester,
      stop: () => find.text('动态 34').evaluate().isNotEmpty,
    );
    expect(find.text('动态 34'), findsOneWidget);
  });

  testWidgets('切回「全部」恢复关注流; 换艺人重置游标(重新从 -1 取)', (tester) async {
    final calls = <({BigInt uid, int lastTime})>[];
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(1, userId: 10, name: '艺人甲'),
            event(2, userId: 20, name: '艺人乙'),
          ],
          loadSubscribedArtists: () async => const [],
          loadArtistEvents:
              ({
                required BigInt uid,
                required int limit,
                required int lastTime,
              }) async {
                calls.add((uid: uid, lastTime: lastTime));
                return [event(101, userId: 20, name: '艺人乙', text: '艺人乙的历史')];
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tapChip(tester, '艺人乙');
    expect(find.text('艺人乙的历史'), findsOneWidget);

    // 切回「全部」: 关注流重新可见
    await tapChip(tester, '全部');
    expect(find.text('动态 1'), findsOneWidget);
    expect(find.text('艺人乙的历史'), findsNothing);

    // 再选中同一个艺人: 游标重置, 重新用 -1 取最新一页
    await tapChip(tester, '艺人乙');
    expect(calls.length, 2);
    expect(calls.last.lastTime, -1);
  });

  testWidgets('艺人流为空时显示空态而不是错误', (tester) async {
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [event(1, userId: 20, name: '艺人乙')],
          loadSubscribedArtists: () async => const [],
          loadArtistEvents: ({
            required BigInt uid,
            required int limit,
            required int lastTime,
          }) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tapChip(tester, '艺人乙');
    expect(find.text('ta 最近没有动态'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });
}
