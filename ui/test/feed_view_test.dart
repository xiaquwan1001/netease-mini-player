import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.FeedEventDto event({
  required int id,
  required int userId,
  required String userName,
  String text = '正文',
  int likedCount = 0,
  int commentCount = 0,
  int shareCount = 0,
}) =>
    rust.FeedEventDto(
      id: BigInt.from(id),
      threadId: 'A_EV_2_${id}_$userId',
      userId: BigInt.from(userId),
      kind: 'text',
      userName: userName,
      text: text,
      images: const [],
      title: '',
      timeMs: BigInt.from(1700000000000 - id * 1000),
      liked: false,
      likedCount: BigInt.from(likedCount),
      shareCount: BigInt.from(shareCount),
      commentCount: BigInt.from(commentCount),
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('艺人分类按互动频率排序, 末尾有"进入全部"', (tester) async {
    final events = <rust.FeedEventDto>[
      // 低互动: 只有 1 条动态, 没有互动
      event(id: 1, userId: 10, userName: '低互动艺人'),
      // 高互动: 2 条动态 + 大量点赞/评论/转发
      event(id: 2, userId: 20, userName: '高互动艺人', likedCount: 100),
      event(
        id: 3,
        userId: 20,
        userName: '高互动艺人',
        likedCount: 50,
        commentCount: 20,
        shareCount: 10,
      ),
    ];

    await tester.pumpWidget(host(FeedView(
      loggedIn: true,
      onLogin: () {},
      onPlaySongs: (_, __) {},
      onOpenUrl: (_) async {},
      loadFeed: () async => events,
      loadSubscribedArtists: () async => const [],
    )));
    await tester.pumpAndSettle();

    // .first = 分类行里的那个(它在动态列表上方, 树序在前)
    final high = tester.getTopLeft(find.text('高互动艺人').first).dx;
    final low = tester.getTopLeft(find.text('低互动艺人').first).dx;
    expect(high, lessThan(low), reason: '互动频率高的艺人要排在前面');
    expect(find.text('进入全部'), findsOneWidget);
  });

  testWidgets('进入全部: 列出本页艺人 + 已关注但无动态的艺人', (tester) async {
    final events = <rust.FeedEventDto>[
      event(id: 1, userId: 10, userName: '本页艺人', likedCount: 5),
    ];

    await tester.pumpWidget(host(FeedView(
      loggedIn: true,
      onLogin: () {},
      onPlaySongs: (_, __) {},
      onOpenUrl: (_) async {},
      loadFeed: () async => events,
      loadSubscribedArtists: () async => [
        rust.ArtistDto(id: BigInt.from(10), name: '本页艺人'),
        rust.ArtistDto(id: BigInt.from(99), name: '没发动态的艺人'),
      ],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('进入全部'));
    await tester.pumpAndSettle();

    expect(find.text('全部艺人'), findsOneWidget);
    expect(find.text('全部动态'), findsOneWidget);
    expect(find.text('本页艺人'), findsWidgets);
    expect(find.text('没发动态的艺人'), findsOneWidget);
    expect(find.text('已关注 · 本页暂无动态'), findsOneWidget);

    // 选中后筛选生效: 这位艺人本页没有动态
    await tester.tap(find.text('没发动态的艺人'));
    await tester.pumpAndSettle();
    expect(find.text('ta 最近没有动态'), findsOneWidget);
  });
}
