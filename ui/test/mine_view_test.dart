import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手',
      artistId: BigInt.one,
      album: '专辑',
      albumId: BigInt.one,
      coverUrl: null,
      durationMs: BigInt.from(1000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

MineView buildMine({
  required bool loggedIn,
  void Function(List<rust.SongDto>, int)? onPlay,
  VoidCallback? onLogin,
}) =>
    MineView(
      loggedIn: loggedIn,
      onLogin: onLogin ?? () {},
      onOpenAccounts: () {},
      loadLiked: () async => [song(1, '喜欢的歌')],
      loadPlaylists: () async => [
        rust.Playlist(
          id: BigInt.from(2),
          name: '收藏歌单',
          coverUrl: null,
          trackCount: BigInt.from(5),
          special: false,
        ),
      ],
      loadPodcasts: () async => [
        rust.PodcastRadio(
          id: BigInt.from(3),
          name: '收藏播客',
          coverUrl: null,
          description: '',
          djName: '主播',
          programCount: BigInt.from(2),
          playCount: BigInt.zero,
        ),
      ],
      onPlaySongs: onPlay ?? (_, _) {},
      onOpenPlaylist: (_) {},
      onOpenPodcast: (_) {},
      onOpenLiked: () {},
      onOpenRecent: () {},
      onOpenFollows: () async {},
      onOpenFolloweds: () async {},
      onOpenAlbum: (_) {},
      loadAlbums: () async => [
        rust.AlbumItem(
          id: BigInt.from(4),
          name: '收藏专辑',
          coverUrl: null,
          artist: '歌手',
          trackCount: BigInt.from(10),
        ),
      ],
      loadRecent: () async => [song(7, '最近听的歌')],
      loadRanking: (period) async => [
        rust.PlayRankEntryDto(
          song: song(period == 'week' ? 9 : 8, period == 'week' ? '本周常听' : '最常听'),
          playCount: BigInt.from(period == 'week' ? 3 : 42),
          score: BigInt.from(period == 'week' ? 30 : 420),
        ),
      ],
    );

void main() {
  testWidgets('未登录时只显示登录引导', (tester) async {
    var logins = 0;
    await tester.pumpWidget(host(buildMine(loggedIn: false, onLogin: () => logins++)));
    expect(find.textContaining('登录后查看'), findsOneWidget);
    await tester.tap(find.text('登录'));
    expect(logins, 1);
  });

  testWidgets('登录后展示我喜欢/歌单/播客(关注艺人在独立 tab)', (tester) async {
    List<rust.SongDto>? played;
    int? index;
    await tester.pumpWidget(host(buildMine(
      loggedIn: true,
      onPlay: (songs, i) {
        played = songs;
        index = i;
      },
    )));
    await tester.pumpAndSettle();

    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('喜欢的歌'), findsOneWidget);
    expect(find.text('收藏的歌单'), findsOneWidget);

    await tester.tap(find.text('喜欢的歌'));
    expect(played?.single.name, '喜欢的歌');
    expect(index, 0);

    // 下半部分要滚动才会被 ListView 构建
    await tester.drag(find.byType(ListView).first, const Offset(0, -1400));
    await tester.pumpAndSettle();
    expect(find.text('收藏播客'), findsOneWidget);
    expect(find.text('收藏的专辑'), findsOneWidget);
    // 关注艺人不在这里: 已挪到独立的「关注」tab
    expect(find.text('关注艺人'), findsNothing);
  });

  testWidgets('登录后下方有听歌排行, 支持总排行/当周切换', (tester) async {
    await tester.pumpWidget(host(buildMine(loggedIn: true)));
    await tester.pumpAndSettle();

    // 听歌排行在"我的"最下方(收藏专辑/最近听过都在它前面), 要滚到底
    await tester.scrollUntilVisible(
      find.text('当周'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('听歌排行'), findsOneWidget);
    expect(find.text('最常听'), findsOneWidget);

    await tester.tap(find.text('当周'));
    await tester.pumpAndSettle();
    expect(find.text('本周常听'), findsOneWidget);
    expect(find.text('最常听'), findsNothing);
  });

  testWidgets('300dp + 1.25 字号: 未登录引导不溢出', (tester) async {
    await pumpNarrow(tester, Scaffold(body: buildMine(loggedIn: false)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('登录后查看'), findsOneWidget);
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(1.25)),
      child: child!,
    ),
    home: home,
  ));
}
