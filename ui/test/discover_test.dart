import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/daily_cache.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/rust/api.dart' as rust;

import 'support/fakes.dart';

// 共享工厂 + 本文件口径(歌单首数由调用方给), 位置参数签名保持不变。
rust.Playlist playlist(int id, String name, int count) =>
    fakePlaylist(id: id, name: name, trackCount: count);

Widget host(VoidCallback onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => TextButton(onPressed: onTap, child: const Text('open')),
    ),
  ),
);

/// 长标题走跑马灯(无限循环动画)时 pumpAndSettle 永不收敛, 固定推进若干帧
/// 让 FutureBuilder/布局稳定即可(与 queue_sheet_test 同款处理).
Future<void> pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

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
          loadSongs: () async => [
            fakeSong(id: 1, name: '晴天'),
            fakeSong(id: 2, name: '七里香'),
          ],
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
          loadSongs: () async => [fakeSong(id: 1, name: '晴天')],
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
          loadRecent: () async => [fakeSong(id: 3, name: '最近一首')],
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
          loadRecent: () async => [fakeSong(id: 3, name: '最近一首')],
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

  // v0.7.2: 行尾的"不感兴趣"按钮已去掉(它白吃 ~48dp 横向空间, 同一动作在
  // 行尾「...」菜单里, 由 SongActionSource.dailyRecommend 决定是否显示)。
  testWidgets('每日推荐: 行尾不再有不感兴趣按钮, 横向空间让给歌名', (tester) async {
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          loadSongs: () async => [
            fakeSong(id: 1, name: '晴天'),
            fakeSong(id: 2, name: '七里香'),
          ],
          loadPlaylists: () async => const [],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('不感兴趣'), findsNothing);
    // 每行只留一个行尾按钮(「...」更多操作)
    expect(find.text('晴天'), findsOneWidget);
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
          loadHistorySongs: (date) async => [fakeSong(id: 7, name: '$date 的歌')],
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

  testWidgets('历史日推: 本地缓存天与在线日期合并去重, 并标「本地」', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (pl) => opened.add(pl.name),
          loadSongs: () async => const [],
          loadPlaylists: () async => const [],
          loadHistoryDates: () async => ['2024-06-20'],
          loadHistorySongs: (date) async => [fakeSong(id: 7, name: '$date 的歌')],
          loadLocalDays: () async => [
            DailyCacheDay(
              date: '2024-06-21',
              playlists: [playlist(5, '本地歌单', 8)],
            ),
            DailyCacheDay(
              date: '2024-06-20',
              playlists: [playlist(6, '重复日的缓存', 3)],
            ),
          ],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();

    // 合并去重: 06-20 只留一行(在线 + 本地合成同一行), 06-21 是纯本地
    expect(find.text('2024-06-20'), findsOneWidget);
    expect(find.text('2024-06-21'), findsOneWidget);
    expect(find.text('本地'), findsNWidgets(2));

    // 纯本地日期: 直接展示缓存的推荐歌单, 点开回调给上层
    await tester.tap(find.text('2024-06-21'));
    await tester.pumpAndSettle();
    expect(find.text('2024-06-21 的日推'), findsOneWidget);
    expect(find.text('本地缓存的推荐歌单(1)'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, '本地歌单'));
    await tester.pumpAndSettle();
    expect(opened, ['本地歌单']);
  });

  testWidgets('历史日推: 在线日期同时有本地缓存时曲目与歌单都展示', (tester) async {
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          loadSongs: () async => const [],
          loadPlaylists: () async => const [],
          loadHistoryDates: () async => ['2024-06-20'],
          loadHistorySongs: (date) async => [fakeSong(id: 7, name: '$date 的歌')],
          loadLocalDays: () async => [
            DailyCacheDay(
              date: '2024-06-20',
              playlists: [playlist(6, '重复日的缓存', 3)],
            ),
          ],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2024-06-20'));
    await tester.pumpAndSettle();

    expect(find.text('2024-06-20 的歌'), findsOneWidget);
    expect(find.text('本地缓存的推荐歌单(1)'), findsOneWidget);
    expect(find.text('重复日的缓存'), findsOneWidget);
  });

  testWidgets('历史日推: 在线接口失败但本地有缓存时仍列出(不整屏报错)', (tester) async {
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          loadSongs: () async => const [],
          loadPlaylists: () async => const [],
          loadHistoryDates: () async => throw Exception('[auth] 需要登录'),
          loadHistorySongs: (date) async => const [],
          loadLocalDays: () async => [
            DailyCacheDay(
              date: '2024-06-21',
              playlists: [playlist(5, '本地歌单', 8)],
            ),
          ],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();

    expect(find.text('2024-06-21'), findsOneWidget);
    expect(find.text('在线历史日推获取失败'), findsOneWidget);
    expect(find.text('本地'), findsOneWidget);
  });

  testWidgets('历史日推: 在线失败且本地无缓存时整屏报错, 重试后恢复', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      host(() {
        showDiscoverPage(
          tester.element(find.text('open')),
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          loadSongs: () async => const [],
          loadPlaylists: () async => const [],
          loadHistoryDates: () async {
            calls++;
            if (calls == 1) throw Exception('[auth] 需要登录');
            return ['2024-06-20'];
          },
          loadHistorySongs: (date) async => const [],
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();

    // 在线挂了且本地没缓存: 整屏错误(不是"空态")
    expect(find.textContaining('需要登录'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('2024-06-20'), findsOneWidget);
    expect(calls, 2);
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
                loadRecent: () async => [
                  fakeSong(id: 3, name: '一首名字特别特别长的歌用于窄屏回归测试'),
                ],
                loadAlbums: () async => [
                  rust.AlbumItem(
                    id: BigInt.from(11),
                    name: '一张名字特别特别长的专辑用于窄屏回归测试',
                    coverUrl: null,
                    artist: '一个名字特别特别长的艺人用于窄屏回归测试',
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
    // 长歌名/歌单名走跑马灯(无限动画), pumpAndSettle 永不收敛 → 固定帧推进.
    await pumpFrames(tester);

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
