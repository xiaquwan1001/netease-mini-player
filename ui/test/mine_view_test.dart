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
        rust.PlaylistDto(
          id: BigInt.from(2),
          name: '收藏歌单',
          coverUrl: null,
          trackCount: BigInt.from(5),
          special: false,
        ),
      ],
      loadPodcasts: () async => [
        rust.PodcastRadioDto(
          id: BigInt.from(3),
          name: '收藏播客',
          coverUrl: null,
          description: '',
          djName: '主播',
          programCount: BigInt.from(2),
          playCount: BigInt.zero,
        ),
      ],
      onPlaySongs: onPlay ?? (_, __) {},
      onOpenPlaylist: (_) {},
      onOpenPodcast: (_) {},
      onOpenLiked: () {},
      onOpenRecent: () {},
      loadRecent: () async => [song(7, '最近听的歌')],
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
    // 关注艺人不在这里: 已挪到独立的「关注」tab
    expect(find.text('关注艺人'), findsNothing);
  });
}
