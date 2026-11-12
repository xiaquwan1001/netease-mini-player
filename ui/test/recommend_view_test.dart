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

rust.Playlist playlist(int id, String name) => rust.Playlist(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      trackCount: BigInt.from(3),
      special: false,
    );

rust.PodcastRadio radio(int id, String name) => rust.PodcastRadio(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      description: '',
      djName: '主播',
      programCount: BigInt.from(2),
      playCount: BigInt.zero,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void narrow(WidgetTester tester) {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget scaled(Widget child) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
        child: Scaffold(body: child),
      ),
    );

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
    rust.Playlist? openedPlaylist;
    rust.PodcastRadio? openedRadio;
    rust.AlbumItem? openedAlbum;
    var heart = 0;
    var moreTaps = 0;

    await tester.pumpWidget(host(RecommendView(
      loggedIn: true,
      loadDailySongs: () async => [song(1, '每日一歌'), song(2, '每日二歌')],
      loadDailyPlaylists: () async => [playlist(10, '推荐歌单A')],
      loadPodcasts: () async => [radio(20, '推荐播客A')],
      loadFm: () async => [song(3, 'FM 曲')],
      loadStyles: () async => const [
        rust.StyleTag(id: '1009', name: '粤语流行'),
        rust.StyleTag(id: '1020', name: '华语流行'),
      ],
      loadCharts: () async => [
        rust.ChartSummary(
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
        rust.AlbumItem(
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

    // 排行榜已按用户要求从推荐页移到搜索页(这里不再渲染)
    expect(find.text('排行榜'), findsNothing);
    expect(find.text('飙升榜'), findsNothing);

    // 风格推荐
    expect(find.text('风格推荐'), findsOneWidget);
    expect(find.text('粤语流行'), findsOneWidget);
    expect(find.text('华语流行'), findsOneWidget);

    // 每日推荐(批次 C: 「每日推荐歌曲」与「每日推荐歌单」合并成一格;
    // 「每日推荐」文案同时出现在快捷卡与区块标题上, 所以是 findsNWidgets(2))
    expect(find.text('每日推荐'), findsNWidgets(2));
    expect(find.text('每日一歌'), findsOneWidget);
    await tester.tap(find.text('每日二歌'));
    expect(played?.length, 2);
    expect(playedIndex, 1);

    // 新歌速递(带"更多"入口 → 新歌/新碟/歌手分类页)
    expect(find.text('新歌速递'), findsOneWidget);
    expect(find.text('新歌速递一'), findsOneWidget);
    // 排行榜搬走后剩 4 个「全部」:
    // 每日推荐 / 推荐歌单 / 新歌新碟 / 推荐播客
    expect(find.text('更多'), findsNothing);
    expect(find.text('查看全部'), findsNothing);
    expect(find.text('全部'), findsNWidgets(4));
    // at(2) = 新歌新碟 标题右侧那个(顺序: 每日推荐, 推荐歌单, 新歌新碟, 播客)
    await tester.tap(find.text('全部').at(2));
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

  testWidgets('300dp + 1.25 字号不溢出(长名日推/歌单/播客/榜单)', (tester) async {
    narrow(tester);
    await tester.pumpWidget(scaled(RecommendView(
      loggedIn: true,
      loadDailySongs: () async =>
          [song(1, '一首名字特别特别长的日推歌曲用于小屏回归测试')],
      loadDailyPlaylists: () async =>
          [playlist(10, '一个名字特别特别长的推荐歌单用于小屏回归测试')],
      loadPodcasts: () async =>
          [radio(20, '一个名字特别特别长的推荐播客用于小屏回归测试')],
      loadFm: () async => [song(3, 'FM 曲')],
      loadStyles: () async =>
          const [rust.StyleTag(id: '1009', name: '粤语流行')],
      loadCharts: () async => [
        rust.ChartSummary(
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
        rust.AlbumItem(
          id: BigInt.from(40),
          name: '新碟A',
          coverUrl: null,
          artist: '歌手',
          trackCount: BigInt.from(8),
        ),
      ],
      onOpenAlbum: (_) {},
      onOpenNewRelease: () {},
      onPlaySongs: (_, _) {},
      onOpenPlaylist: (_) {},
      onOpenPodcast: (_) {},
      onHeartMode: () {},
      onOpenDaily: () {},
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('每日推荐'), findsWidgets);
    // 排行榜已搬到搜索页, 窄屏下这里只校验页面本身不溢出
    expect(find.text('风格推荐'), findsOneWidget);
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
