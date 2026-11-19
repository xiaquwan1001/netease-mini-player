import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_page.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_page.dart';

/// 刷新语义回归(2026-11-18 用户反馈 3):
///
///   · 「刷新后条目变少」: 最新页(lastTime=-1)常常只回 1 条, 整体替换会把 3 条
///     变 1 条 —— 关注流 / 用户空间 / 艺人空间的动态列表**都必须并进**已有条目。
///   · 桌面没有下拉刷新: 滚轮到顶继续上滚要能触发一次刷新(1.5s 冷却内只算一次);
///     非顶部(列表还能滚)时不能误触发。

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

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

FeedView feed({
  required Future<List<rust.FeedEventDto>> Function() loadFeed,
  Future<List<rust.FeedEventDto>> Function({
    required BigInt uid,
    required int limit,
    required int lastTime,
  })?
  loadArtistEvents,
}) => FeedView(
  loggedIn: true,
  onLogin: () {},

  onOpenUrl: (_) async {},
  loadFeed: loadFeed,
  loadSubscribedArtists: () async => const [],
  loadArtistEvents: loadArtistEvents,
);

/// 竖向列表(下拉刷新的那个), 横条是 horizontal 的
Finder verticalList() => find
    .byWidgetPredicate(
      (w) => w is ListView && w.scrollDirection == Axis.vertical,
    )
    .first;

/// 在列表中心发一次滚轮事件
Future<void> wheel(WidgetTester tester, double dy) async {
  await tester.sendEventToBinding(
    PointerScrollEvent(
      position: tester.getCenter(verticalList()),
      scrollDelta: Offset(0, dy),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 触发一次 RefreshIndicator(移动端的手指下拉)
Future<void> pullToRefresh(WidgetTester tester) async {
  await tester.fling(verticalList(), const Offset(0, 400), 1200);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('关注流: 已有 3 条 + 刷新只回 1 条 ⇒ 列表仍不少', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        feed(
          loadFeed: () async {
            calls++;
            if (calls == 1) return [ev(1), ev(2), ev(3)];
            return [ev(9)];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNWidgets(3));

    await pullToRefresh(tester);

    expect(calls, 2);
    expect(find.byType(Card), findsNWidgets(4), reason: '刷新是合并, 不是替换');
  });

  testWidgets('关注流: 筛选某作者后刷新, 筛选与条目都保留', (tester) async {
    var calls = 0;
    var artistCalls = 0;
    await tester.pumpWidget(
      host(
        feed(
          loadFeed: () async {
            calls++;
            if (calls == 1) {
              return [
                ev(1, userId: 10, name: '甲艺人'),
                ev(2, userId: 20, name: '乙艺人'),
                ev(3, userId: 20, name: '乙艺人'),
              ];
            }
            // 刷新回来的最新页里有一条乙艺人的新动态
            return [ev(9, userId: 20, name: '乙艺人')];
          },
          // 关注页选中艺人后数据源切到 ta 自己的动态流(用户反馈 2026-11-19):
          // 首屏回本页该艺人的 2 条, 刷新回 1 条新的
          loadArtistEvents:
              ({
                required BigInt uid,
                required int limit,
                required int lastTime,
              }) async {
                artistCalls++;
                if (artistCalls == 1) {
                  return [
                    ev(2, userId: 20, name: '乙艺人'),
                    ev(3, userId: 20, name: '乙艺人'),
                  ];
                }
                return [ev(9, userId: 20, name: '乙艺人')];
              },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 横条上的「乙艺人」(树序在卡片之前)
    await tester.tap(find.text('乙艺人').first);
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNWidgets(2));

    expect(artistCalls, 1, reason: '选中艺人后首屏取该艺人自己的动态流');

    await pullToRefresh(tester);

    expect(artistCalls, 2, reason: '刷新重取该艺人最新一页');
    expect(calls, 1, reason: '艺人模式不再重取关注流');
    expect(find.byType(Card), findsNWidgets(3), reason: '原 2 条 + 刷新来的 1 条');
    // 筛选没被刷新重置: 甲艺人的动态仍不显示
    expect(find.text('动态 1'), findsNothing);
  });

  testWidgets('桌面滚轮到顶再上滚: 触发一次; 1.5s 内重复只算一次', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        feed(
          loadFeed: () async {
            calls++;
            return [ev(1), ev(2)];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    await wheel(tester, -120);
    await tester.pumpAndSettle();
    expect(calls, 2, reason: '顶部继续上滚 = 刷新');

    // 冷却期内再滚: 不再触发
    await wheel(tester, -120);
    await tester.pumpAndSettle();
    expect(calls, 2);

    // 冷却结束后再滚: 又能触发一次
    await tester.pump(const Duration(milliseconds: 1600));
    await wheel(tester, -120);
    await tester.pumpAndSettle();
    expect(calls, 3);
  });

  testWidgets('桌面滚轮: 非顶部不触发刷新', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        feed(
          loadFeed: () async {
            calls++;
            return [
              for (var i = 1; i <= 20; i++) ev(i, text: '动态 $i 的正文比较长一点'),
            ];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);

    // 先往下滚一段(列表离开顶部)
    await tester.drag(verticalList(), const Offset(0, -400));
    await tester.pumpAndSettle();

    await wheel(tester, -120);
    await tester.pumpAndSettle();
    expect(calls, 1, reason: '列表还能滚时上滚只是普通滚动');
  });

  testWidgets('用户空间动态: 刷新只回 1 条也不清掉已有条目', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(42),
          fallbackNickname: '某人',
          loadProfile: (uid) async => rust.ProfileDetail(
            userId: uid,
            nickname: '某人',
            signature: '',
            vip: false,
            follows: BigInt.one,
            followeds: BigInt.one,
            level: BigInt.one,
          ),
          loadPlaylists: (uid) async => const [],
          loadEvents: (uid) async {
            calls++;
            if (calls == 1) {
              return [
                ev(1, text: '第一条动态'),
                ev(2, text: '第二条动态'),
                ev(3, text: '第三条动态'),
              ];
            }
            return [ev(9, text: '刷新回来的新动态')];
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('第一条动态'), findsOneWidget);
    expect(find.text('第三条动态'), findsOneWidget);

    await pullToRefresh(tester);

    expect(calls, greaterThan(1));
    expect(find.text('第一条动态'), findsOneWidget, reason: '已展示的条目不能被刷新清掉');
    expect(find.text('第三条动态'), findsOneWidget);
    expect(find.text('刷新回来的新动态'), findsOneWidget);
  });

  testWidgets('艺人空间动态: 刷新只回 1 条也不清掉已有条目', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(
        ArtistDetailPage(
          artistId: BigInt.from(6452),
          loadArtist: (id) async => rust.ArtistDetailDto(
            id: id,
            name: '周杰伦',
            avatarUrl: null,
            coverUrl: null,
            alias: const [],
            briefDesc: '',
            albumCount: BigInt.zero,
            musicCount: BigInt.zero,
            fansCount: BigInt.zero,
            followed: false,
            userId: BigInt.from(6452),
            eventCount: BigInt.from(3),
            songs: const [],
            albums: const [],
          ),
          loadSimilar: (id) async => const [],
          loadSongsPage: (id, offset) async =>
              const rust.ArtistSongPageDto(songs: [], hasMore: false),
          loadMvsPage: (id, offset) async =>
              const rust.ArtistMvPageDto(mvs: [], hasMore: false),
          loadDynamics: (uid) async {
            calls++;
            if (calls == 1) {
              return [
                ev(1, text: '艺人第一条'),
                ev(2, text: '艺人第二条'),
                ev(3, text: '艺人第三条'),
              ];
            }
            return [ev(9, text: '艺人刷新回来的新动态')];
          },
          toggleFollow: (id, sub) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 切到「动态」tab(它是最后一条)
    await tester.tap(find.text('动态').last);
    await tester.pumpAndSettle();
    expect(find.text('艺人第三条'), findsOneWidget);

    await pullToRefresh(tester);

    expect(calls, greaterThan(1));
    expect(find.text('艺人第一条'), findsOneWidget, reason: '已展示的条目不能被刷新清掉');
    expect(find.text('艺人第三条'), findsOneWidget);
    expect(find.text('艺人刷新回来的新动态'), findsOneWidget);
  });
}
