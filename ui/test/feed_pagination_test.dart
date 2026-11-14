import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// 动态流分页回归: 滚动到底加载更早(游标 = 最后一条 time_ms)、
/// 下拉刷新只刷最新页并与历史按 id 合并去重。

/// 时间从新到旧: id 越大越早
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
  group('mergeFeedEvents', () {
    test('按 id 去重, 第一页副本优先, 新条目追加在末尾', () {
      final merged = mergeFeedEvents(
        [event(1), event(2)],
        [event(2), event(3)],
      );
      expect(merged.map((e) => e.id.toInt()).toList(), [1, 2, 3]);
    });

    test('刷新: 最新页在前, 历史不丢, 同 id 用最新副本', () {
      final stale = event(2);
      final fresh = event(2);
      final history = event(5);
      final merged = mergeFeedEvents([fresh], [stale, history]);
      expect(merged.length, 2);
      expect(merged.first.text, fresh.text);
      expect(merged.last.id.toInt(), 5);
    });
  });

  testWidgets('滚动到底用最后一条 time_ms 拉更早一页并去重追加', (tester) async {
    final calls = <Map<String, int>>[];
    // 第一页满页(30 条), 才可能还有更早
    final newest = [for (var i = 1; i <= 30; i++) event(i)];
    // 更早一页: 与第一页最后一条重复(id 30), 新增 31..34
    final older = [for (var i = 30; i <= 34; i++) event(i)];

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => newest,
          loadSubscribedArtists: () async => const [],
          loadOlder: ({required int limit, required int lastTime}) async {
            calls.add({'limit': limit, 'lastTime': lastTime});
            return older;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);

    await dragToBottom(tester, stop: () => calls.isNotEmpty);
    expect(calls.length, 1);
    // 游标 = 第一页最后一条(id 30)的 time_ms
    expect(calls.first['limit'], 30);
    expect(calls.first['lastTime'], 1700000000000 - 30 * 1000);

    // 更早一页只有 4 条新增(不满页) ⇒ 不再继续请求
    await tester.pumpAndSettle();
    await dragToBottom(
      tester,
      stop: () => find.text('动态 34').evaluate().isNotEmpty,
    );
    expect(find.text('动态 34'), findsOneWidget);
    expect(calls.length, 1);
  });

  testWidgets('下拉刷新只刷最新页, 已加载的历史不被清掉', (tester) async {
    var loads = 0;
    final calls = <int>[];
    final newest = [for (var i = 1; i <= 30; i++) event(i)];
    final older = [for (var i = 31; i <= 34; i++) event(i)];

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async {
            loads++;
            return newest;
          },
          loadSubscribedArtists: () async => const [],
          loadOlder: ({required int limit, required int lastTime}) async {
            calls.add(lastTime);
            return older;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loads, 1);

    // 先滚到底把历史翻出来
    await dragToBottom(tester, stop: () => calls.isNotEmpty);
    await tester.pumpAndSettle();
    expect(calls.length, 1);

    // 回到顶部并下拉刷新
    final list = find.byType(ListView).last;
    await tester.drag(list, const Offset(0, 4000));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.fling(list, const Offset(0, 400), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    expect(loads, 2, reason: '下拉刷新应重取最新页');
    // 刷新没有重新请求更早的页(游标次数不变)
    expect(calls.length, 1);

    // 历史(id 34)仍在: 滚到底部仍能找到
    await dragToBottom(
      tester,
      stop: () => find.text('动态 34').evaluate().isNotEmpty,
    );
    expect(find.text('动态 34'), findsOneWidget);
    expect(calls.length, 1);
  });
}
