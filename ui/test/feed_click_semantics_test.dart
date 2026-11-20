import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart' show CircleCover;
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/user_nav.dart';

/// 点击语义统一(2026-11-18 用户反馈 2):
///
///   横条: 点圆形头像 **只做页内聚焦**(不再进用户空间详情, 与点 chip 其它位置一致)
///   卡片: 点头像才进用户空间详情(唯一的主页入口)
///
/// 之前横条头像单独包了 UserAvatarTap: 同一块 64dp 的 chip 上, 点头像去主页、
/// 点名字筛动态 —— 两种结果最容易误触。

rust.FeedEventDto ev(
  int id, {
  int userId = 10,
  String name = '艺人甲',
  String text = '',
  int liked = 0,
}) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_$userId',
  userId: BigInt.from(userId),
  kind: 'text',
  userName: name,
  avatarUrl: null,
  text: text.isEmpty ? '动态 $id' : text,
  song: null,
  coverUrl: null,
  images: const [],
  videoUrl: null,
  title: '',
  timeMs: BigInt.from(1700000000000 - id * 1000),
  liked: false,
  likedCount: BigInt.from(liked),
  shareCount: BigInt.zero,
  commentCount: BigInt.zero,
);

Widget host(Widget child, {List<NavigatorObserver> observers = const []}) =>
    MaterialApp(
      navigatorObservers: observers,
      home: Scaffold(body: child),
    );

/// 数"压了几条路由"(初始路由 didPush 一次, 断言只看增量)
class _PushCounter extends NavigatorObserver {
  int pushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

/// 横条里的圆形头像(第一个作者 chip 的)
Finder barAvatar() => find
    .descendant(
      of: find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal,
      ),
      matching: find.byType(CircleCover),
    )
    .first;

void main() {
  late List<BigInt> opened;

  setUp(() {
    opened = <BigInt>[];
    UserNav.opener = (context, userId, {nickname}) async {
      opened.add(userId);
    };
  });

  tearDown(() {
    UserNav.opener = null;
    UserNav.userOpener = null;
    UserNav.artistIdResolver = null;
    UserNav.clearCache();
  });

  testWidgets('横条点圆形头像: 只聚焦, push 路由 0 次', (tester) async {
    final counter = _PushCounter();
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},

          onOpenUrl: (_) async {},
          loadFeed: () async => [
            ev(1, userId: 10, name: '甲艺人'),
            ev(2, userId: 20, name: '乙艺人'),
          ],
          loadSubscribedArtists: () async => const [],
          // 选中艺人后数据源切到 ta 自己的动态流(不再是本页客户端过滤)
          loadArtistEvents: ({
            required BigInt uid,
            required int limit,
            required int lastTime,
          }) async => [ev(1, userId: 10, name: '甲艺人')],
        ),
        observers: [counter],
      ),
    );
    await tester.pumpAndSettle();

    final before = counter.pushes;
    expect(find.byType(Card), findsNWidgets(2));

    await tester.tap(barAvatar());
    await tester.pumpAndSettle();

    expect(opened, isEmpty, reason: '横条头像不再进用户空间详情');
    expect(counter.pushes, before, reason: '没有新路由');
    expect(find.byType(Card), findsOneWidget, reason: '点 chip 就是页内聚焦');
  });

  testWidgets('卡片点头像: 进用户空间详情(push 一条路由)', (tester) async {
    UserNav.opener = (context, userId, {nickname}) async {
      opened.add(userId);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('用户空间')),
        ),
      );
    };
    final counter = _PushCounter();
    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},

          onOpenUrl: (_) async {},
          loadFeed: () async => [ev(1, userId: 42, name: '某人')],
          loadSubscribedArtists: () async => const [],
        ),
        observers: [counter],
      ),
    );
    await tester.pumpAndSettle();

    final before = counter.pushes;
    // 卡片上的头像走 UserAvatarTap(UserNav 的唯一入口, 不新造导航)
    await tester.tap(find.byType(UserAvatarTap).first);
    await tester.pumpAndSettle();

    expect(opened, [BigInt.from(42)]);
    expect(counter.pushes, before + 1);
    expect(find.text('用户空间'), findsOneWidget);
  });
}
