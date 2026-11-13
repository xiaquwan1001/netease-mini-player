import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/discover.dart';
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

rust.Playlist playlist(int id, String name, int count) => rust.Playlist(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  trackCount: BigInt.from(count),
  special: false,
);

Widget host(VoidCallback onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => TextButton(onPressed: onTap, child: const Text('open')),
    ),
  ),
);

void main() {
  testWidgets('每日推荐: 歌曲列表可点, 回调整批曲目与下标', (tester) async {
    List<rust.SongDto>? played;
    int? playedIndex;
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (songs, index) {
            played = songs;
            playedIndex = index;
          },
          onOpenPlaylist: (_) {},
          loadSongs: () async => [song(1, '晴天'), song(2, '七里香')],
          loadPlaylists: () async => [playlist(9, '推荐歌单', 12)],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('每日推荐'), findsOneWidget);
    expect(find.text('晴天'), findsOneWidget);
    expect(find.text('七里香'), findsOneWidget);

    await tester.tap(find.text('七里香'));
    await tester.pumpAndSettle();
    expect(played?.length, 2);
    expect(playedIndex, 1);
  });

  testWidgets('每日推荐: 歌单页签展示并可打开', (tester) async {
    rust.Playlist? opened;
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (pl) => opened = pl,
          loadSongs: () async => [song(1, '晴天')],
          loadPlaylists: () async => [playlist(9, '推荐歌单', 12)],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐歌单').last);
    await tester.pumpAndSettle();
    // 歌单名称 + 曲目数
    expect(find.text('12 首'), findsOneWidget);
    // 全页后 AppBar 的 TabBar 在树里排在 body 之后, find.text().last 会命中
    // tab 标签而不是列表行, 因此这里显式定位列表行。
    await tester.tap(find.widgetWithText(ListTile, '推荐歌单'));
    await tester.pumpAndSettle();
    expect(opened?.id, BigInt.from(9));
  });

  testWidgets('每日推荐: 加载失败展示错误与重试', (tester) async {
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          loadSongs: () async => throw Exception('[network] boom'),
          loadPlaylists: () async => const [],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('最近听过: 列表可点并回调', (tester) async {
    List<rust.SongDto>? played;
    await tester.pumpWidget(
      host(() {
        showRecentPage(
          tester.element(find.text('open')),
          onPlay: (songs, index) => played = songs,
          loadRecent: () async => [song(3, '最近一首')],
          loadAlbums: () async => const [],
          loadPlaylists: () async => const [],
          loadPodcasts: () async => const [],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('最近听过'), findsOneWidget);
    await tester.tap(find.text('最近一首'));
    await tester.pumpAndSettle();
    expect(played?.single.name, '最近一首');
  });

  testWidgets('最近听过: 单曲/专辑/歌单/播客四个分类各自渲染', (tester) async {
    rust.AlbumItem? openedAlbum;
    await tester.pumpWidget(
      host(() {
        showRecentPage(
          tester.element(find.text('open')),
          onPlay: (_, _) {},
          loadRecent: () async => [song(3, '最近一首')],
          loadAlbums: () async => [
            rust.AlbumItem(
              id: BigInt.from(11),
              name: '野泳',
              coverUrl: null,
              artist: '祝游会',
              trackCount: BigInt.from(7),
            ),
          ],
          loadPlaylists: () async => [playlist(9, '最近歌单', 3)],
          loadPodcasts: () async => [
            rust.PodcastRadio(
              id: BigInt.from(7),
              name: '最近播客',
              coverUrl: null,
              description: '',
              djName: '主播',
              programCount: BigInt.from(5),
              playCount: BigInt.zero,
            ),
          ],
          onOpenAlbum: (a) => openedAlbum = a,
          onOpenPlaylist: (_) {},
          onOpenPodcast: (_) {},
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('专辑'));
    await tester.pumpAndSettle();
    expect(find.text('野泳'), findsOneWidget);
    await tester.tap(find.text('野泳'));
    await tester.pumpAndSettle();
    expect(openedAlbum?.name, '野泳');
  });

  testWidgets('最近听过: 歌单/播客页签可打开', (tester) async {
    rust.Playlist? openedPlaylist;
    rust.PodcastRadio? openedPodcast;
    await tester.pumpWidget(
      host(() {
        showRecentPage(
          tester.element(find.text('open')),
          onPlay: (_, _) {},
          loadRecent: () async => const [],
          loadAlbums: () async => const [],
          loadPlaylists: () async => [playlist(9, '最近歌单', 3)],
          loadPodcasts: () async => [
            rust.PodcastRadio(
              id: BigInt.from(7),
              name: '最近播客',
              coverUrl: null,
              description: '',
              djName: '主播',
              programCount: BigInt.from(5),
              playCount: BigInt.zero,
            ),
          ],
          onOpenPlaylist: (p) => openedPlaylist = p,
          onOpenPodcast: (r) => openedPodcast = r,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('歌单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近歌单'));
    await tester.pumpAndSettle();
    expect(openedPlaylist?.name, '最近歌单');

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('播客'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('最近播客'));
    await tester.pumpAndSettle();
    expect(openedPodcast?.name, '最近播客');
  });

  testWidgets('每日推荐: 不感兴趣把歌从列表里去掉', (tester) async {
    final disliked = <String>[];
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          loadSongs: () async => [song(1, '晴天'), song(2, '七里香')],
          loadPlaylists: () async => const [],
          onDislike: (s) async => disliked.add(s.name),
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('不感兴趣'), findsNWidgets(2));
    await tester.tap(find.byTooltip('不感兴趣').first);
    await tester.pumpAndSettle();

    expect(disliked, ['晴天']);
    expect(find.text('晴天'), findsNothing);
    expect(find.text('七里香'), findsOneWidget);
  });

  testWidgets('历史日推: 日期列表 → 某天的歌单', (tester) async {
    List<rust.SongDto>? played;
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (songs, index) => played = songs,
          onOpenPlaylist: (_) {},
          loadSongs: () async => const [],
          loadPlaylists: () async => const [],
          loadHistoryDates: () async => ['2024-06-20', '2024-06-19'],
          loadHistorySongs: (date) async => [song(7, '$date 的歌')],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();
    expect(find.text('2024-06-20'), findsOneWidget);
    expect(find.text('2024-06-19'), findsOneWidget);

    await tester.tap(find.text('2024-06-20'));
    await tester.pumpAndSettle();
    expect(find.text('2024-06-20 的日推'), findsOneWidget);
    expect(find.text('2024-06-20 的歌'), findsOneWidget);

    await tester.tap(find.text('2024-06-20 的歌'));
    await tester.pumpAndSettle();
    expect(played?.single.id, BigInt.from(7));
  });

  testWidgets('最近听过: 300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showRecentPage(
                ctx,
                onPlay: (_, _) {},
                loadRecent: () async => [song(3, '一首名字特别特别长的歌用于窄屏回归测试')],
                loadAlbums: () async => [
                  rust.AlbumItem(
                    id: BigInt.from(11),
                    name: '一张名字特别特别长的专辑用于窄屏回归测试',
                    coverUrl: null,
                    artist: '一个名字特别特别长的歌手用于窄屏回归测试',
                    trackCount: BigInt.from(7),
                  ),
                ],
                loadPlaylists: () async => const [],
                loadPodcasts: () async => const [],
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('最近听过'), findsOneWidget);
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: home,
    ),
  );
}
