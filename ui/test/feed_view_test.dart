import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_nav.dart';
import 'package:minincm/src/feed_detail_page.dart' show feedRelativeTime;
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
}) => rust.FeedEventDto(
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

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => events,
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
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

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => events,
          loadSubscribedArtists: () async => [
            rust.Artist(id: BigInt.from(10), name: '本页艺人'),
            rust.Artist(id: BigInt.from(99), name: '没发动态的艺人'),
          ],
        ),
      ),
    );
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

  testWidgets('横向艺人 chip: 点头像进艺人主页, 点整块仍是筛选', (tester) async {
    final calls = <(BigInt, String?)>[];
    ArtistNav.opener = (context, artistId, {name}) async {
      calls.add((artistId, name));
    };
    addTearDown(() => ArtistNav.opener = null);

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(id: 1, userId: 10, userName: '低互动艺人', text: '低互动正文'),
            event(
              id: 2,
              userId: 20,
              userName: '高互动艺人',
              text: '高互动正文',
              likedCount: 100,
            ),
          ],
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 头像(40dp)是主页入口: 命中区只覆盖头像本身
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is ArtistAvatarTap && w.artistId == BigInt.from(20),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, [(BigInt.from(20), '高互动艺人')]);
    // 筛选没被顺手触发: 两位的动态都还在
    expect(find.text('低互动正文'), findsOneWidget);
    expect(find.text('高互动正文'), findsOneWidget);

    // 整块(chip 文字)仍是筛选: 选中后只显示这一位的动态
    await tester.tap(find.text('低互动艺人').first);
    await tester.pumpAndSettle();
    expect(calls, hasLength(1), reason: '点整块不该进主页');
    expect(find.text('低互动正文'), findsOneWidget);
    expect(find.text('高互动正文'), findsNothing);
  });

  testWidgets('「全部艺人」面板: 点头像进主页, 点整行仍是筛选', (tester) async {
    final calls = <(BigInt, String?)>[];
    ArtistNav.opener = (context, artistId, {name}) async {
      calls.add((artistId, name));
    };
    addTearDown(() => ArtistNav.opener = null);

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [event(id: 1, userId: 10, userName: '本页艺人')],
          loadSubscribedArtists: () async => [
            rust.Artist(id: BigInt.from(10), name: '本页艺人'),
            rust.Artist(id: BigInt.from(99), name: '没发动态的艺人'),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('进入全部'));
    await tester.pumpAndSettle();
    expect(find.text('全部艺人'), findsOneWidget);

    // 已关注块的这一行: 头像用的是 rust.Artist.id
    await tester.tap(
      find.byWidgetPredicate(
        (w) => w is ArtistAvatarTap && w.artistId == BigInt.from(99),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, [(BigInt.from(99), '没发动态的艺人')]);
    // 面板没关、筛选没生效(点头像只是打开主页)
    expect(find.text('全部艺人'), findsOneWidget);

    // 整行仍是筛选: 选中后弹回并只显示这位(本页没他的动态)
    await tester.tap(find.text('没发动态的艺人'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1), reason: '点整行不该进主页');
    expect(find.text('ta 最近没有动态'), findsOneWidget);
  });

  // A3 回归: 头行 = 头像 + 用户名(Expanded) + 相对时间(固定宽度尾部元素)。
  // 修复前时间是裸 Text, 300dp x1.625 下会被挤出屏幕/撑破整行。
  testWidgets('300dp x1.625: 超长用户名 + 相对时间不溢出, 时间单行且在屏内', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.625;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    final e = event(
      id: 1,
      userId: 10,
      userName: '一个名字特别特别长的动态发布者昵称用于窄屏回归测试再加长一点',
      text: '正文',
    );
    // 只收集错误、不改 FlutterError.onError 之外的任何东西: 1.625 下顶部横向
    // 艺人筛选条(_AuthorChip, SizedBox(height: 84) 定高)另有 4dp 的**竖向**溢出,
    // 属本次 A 级清单外(pre-existing), 这里只断言横向不溢出(头行溢出的形态)。
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (d) => errors.add(d.exceptionAsString());
    try {
      await tester.pumpWidget(
        host(
          FeedView(
            loggedIn: true,
            onLogin: () {},
            onPlaySongs: (_, _) {},
            onOpenUrl: (_) async {},
            loadFeed: () async => [e],
            loadSubscribedArtists: () async => const [],
          ),
        ),
      );
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = previous;
    }
    expect(
      errors.where((m) => m.contains('Axis.horizontal')),
      isEmpty,
      reason: '动态头行不允许横向 overflow',
    );
    final time = find.text(feedRelativeTime(e.timeMs));
    expect(time, findsOneWidget);
    final box = tester.renderObject<RenderBox>(time);
    expect(box.size.height, lessThan(40), reason: '相对时间不许竖排');
    final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
    expect(right, lessThanOrEqualTo(300.5), reason: '相对时间被挤出屏幕');
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: FeedView(
            loggedIn: true,
            onLogin: () {},
            onPlaySongs: (_, _) {},
            onOpenUrl: (_) async {},
            loadFeed: () async => const [],
            loadSubscribedArtists: () async => const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
