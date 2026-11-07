import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/recommend_view.dart';
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
  testWidgets('推荐页展示每日推荐/歌单/播客/榜单/新碟, 点歌回调整批曲目', (tester) async {
    // 页面很长(榜单/风格/每日推荐/新歌/歌单/新碟/播客), 用高视口一次构建,
    // 避免在测试里反复滚动造成的不稳定。
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    List<rust.SongDto>? played;
    int? playedIndex;
    rust.PlaylistDto? openedPlaylist;
    rust.PodcastRadioDto? openedRadio;
    rust.AlbumItemDto? openedAlbum;
    var heart = 0;
    var moreTaps = 0;

    await tester.pumpWidget(host(RecommendView(
      loggedIn: true,
      loadDailySongs: () async => [song(1, '每日一歌'), song(2, '每日二歌')],
      loadDailyPlaylists: () async => [playlist(10, '推荐歌单A')],
      loadPodcasts: () async => [radio(20, '推荐播客A')],
      loadFm: () async => [song(3, 'FM 曲')],
      loadStyles: () async => const [
        rust.StyleTagDto(id: '1009', name: '粤语流行'),
        rust.StyleTagDto(id: '1020', name: '华语流行'),
      ],
      loadCharts: () async => [
        rust.ChartSummaryDto(
          id: BigInt.from(19723756),
          name: '飙升榜',
          coverUrl: null,
          updateFrequency: '刚刚更新',
          trackCount: BigInt.from(100),
          playCount: BigInt.from(1000),
        ),
      ],
      loadNewSongs: () async => [song(30, '新歌速递一')],
      loadNewAlbums: () async => [
        rust.AlbumItemDto(
          id: BigInt.from(40),
          name: '新碟A',
          coverUrl: null,
          artist: '歌手',
          trackCount: BigInt.from(8),
        ),
      ],
      onOpenAlbum: (album) => openedAlbum = album,
      onOpenNewRelease: () => moreTaps++,
      onPlaySongs: (songs, index) {
        played = songs;
        playedIndex = index;
      },
      onOpenPlaylist: (p) => openedPlaylist = p,
      onOpenPodcast: (r) => openedRadio = r,
      onHeartMode: () => heart++,
      onOpenDaily: () {},
    )));
    await tester.pumpAndSettle();

    // 排行榜(榜单就是歌单)
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('飙升榜'), findsOneWidget);
    expect(find.text('刚刚更新'), findsOneWidget);

    // 风格推荐
    expect(find.text('风格推荐'), findsOneWidget);
    expect(find.text('粤语流行'), findsOneWidget);
    expect(find.text('华语流行'), findsOneWidget);

    // 每日推荐歌曲
    expect(find.text('每日推荐歌曲'), findsOneWidget);
    expect(find.text('每日一歌'), findsOneWidget);
    await tester.tap(find.text('每日二歌'));
    expect(played?.length, 2);
    expect(playedIndex, 1);

    // 新歌速递(带"更多"入口 → 新歌/新碟/歌手分类页)
    expect(find.text('新歌速递'), findsOneWidget);
    expect(find.text('新歌速递一'), findsOneWidget);
    expect(find.text('更多'), findsNWidgets(3), reason: '新歌速递 + 新碟上架 + 推荐播客各一个');
    await tester.tap(find.text('更多').first);
    await tester.pumpAndSettle();
    expect(moreTaps, 1);

    // 推荐歌单
    expect(find.text('推荐歌单'), findsOneWidget);
    await tester.tap(find.text('推荐歌单A'));
    expect(openedPlaylist?.id, BigInt.from(10));

    // 新碟上架
    expect(find.text('新碟上架'), findsOneWidget);
    await tester.tap(find.text('新碟A'));
    expect(openedAlbum?.id, BigInt.from(40));

    // 推荐播客
    expect(find.text('推荐播客'), findsOneWidget);
    await tester.tap(find.text('推荐播客A'));
    expect(openedRadio?.id, BigInt.from(20));

    // 心动模式快捷卡片
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
      loadStyles: () async => const [],
      loadCharts: () async => const [],
      loadNewSongs: () async => const [],
      loadNewAlbums: () async => const [],
      onPlaySongs: (songs, index) => played = songs,
      onOpenPlaylist: (_) {},
      onOpenPodcast: (_) {},
      onHeartMode: () {},
      onOpenDaily: () {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('私人FM'));
    await tester.pumpAndSettle();
    expect(played?.single.name, 'FM 曲');
  });
}
