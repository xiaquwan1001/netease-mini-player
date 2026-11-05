import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手',
      album: '专辑',
      albumId: BigInt.one,
      coverUrl: null,
      durationMs: BigInt.from(1000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

rust.PlaylistDto playlist(int id, String name) => rust.PlaylistDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      trackCount: BigInt.from(3),
      special: false,
    );

rust.PodcastRadioDto radio(int id, String name) => rust.PodcastRadioDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      description: '',
      djName: '主播',
      programCount: BigInt.from(2),
      playCount: BigInt.zero,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('推荐页展示每日推荐/歌单/播客, 点歌回调整批曲目', (tester) async {
    List<rust.SongDto>? played;
    int? playedIndex;
    rust.PlaylistDto? openedPlaylist;
    rust.PodcastRadioDto? openedRadio;
    var heart = 0;

    await tester.pumpWidget(host(RecommendView(
      loggedIn: true,
      loadDailySongs: () async => [song(1, '每日一歌'), song(2, '每日二歌')],
      loadDailyPlaylists: () async => [playlist(10, '推荐歌单A')],
      loadPodcasts: () async => [radio(20, '推荐播客A')],
      loadFm: () async => [song(3, 'FM 曲')],
      onPlaySongs: (songs, index) {
        played = songs;
        playedIndex = index;
      },
      onOpenPlaylist: (p) => openedPlaylist = p,
      onOpenPodcast: (r) => openedRadio = r,
      onHeartMode: () => heart++,
      onOpenDaily: () {},
      onOpenRecent: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('每日推荐歌曲'), findsOneWidget);
    expect(find.text('推荐歌单'), findsOneWidget);
    expect(find.text('推荐播客'), findsOneWidget);
    expect(find.text('每日一歌'), findsOneWidget);
    expect(find.text('推荐歌单A'), findsOneWidget);
    expect(find.text('推荐播客A'), findsOneWidget);

    await tester.tap(find.text('每日二歌'));
    expect(played?.length, 2);
    expect(playedIndex, 1);

    await tester.tap(find.text('推荐歌单A'));
    expect(openedPlaylist?.id, BigInt.from(10));

    await tester.ensureVisible(find.text('推荐播客A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐播客A'));
    expect(openedRadio?.id, BigInt.from(20));

    await tester.ensureVisible(find.text('心动模式'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('心动模式'));
    expect(heart, 1);
  });

  testWidgets('私人 FM 播放按钮加载后回调曲目', (tester) async {
    List<rust.SongDto>? played;
    await tester.pumpWidget(host(RecommendView(
      loggedIn: true,
      loadDailySongs: () async => const [],
      loadDailyPlaylists: () async => const [],
      loadPodcasts: () async => const [],
      loadFm: () async => [song(7, 'FM 曲')],
      onPlaySongs: (songs, index) => played = songs,
      onOpenPlaylist: (_) {},
      onOpenPodcast: (_) {},
      onHeartMode: () {},
      onOpenDaily: () {},
      onOpenRecent: () {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(played?.single.name, 'FM 曲');
  });
}
