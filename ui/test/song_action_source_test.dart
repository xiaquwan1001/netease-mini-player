import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_actions.dart';

rust.SongDto fakeSong({String name = '测试歌曲'}) => rust.SongDto(
  id: BigInt.from(42),
  name: name,
  artist: '测试艺人',
  artistId: BigInt.one,
  album: '测试专辑',
  albumId: BigInt.one,
  durationMs: BigInt.from(200000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

/// 带 dislike 记录的假 host
class FakeHost {
  FakeHost({this.withDislike = true});

  final bool withDislike;

  int dislikeCalls = 0;
  int playNextCalls = 0;

  late final SongActionHost host = SongActionHost(
    loggedIn: true,
    isLiked: (_) => false,
    toggleLike: (_) async {},
    playNext: (_) async => playNextCalls++,
    addToPlaylist: (_) async {},
    share: (_) async {},
    comments: (_) async {},
    openArtist: (_) async {},
    openAlbum: (_) async {},
    download: (_) async {},
    dislike: withDislike ? (_) async => dislikeCalls++ : null,
  );
}

Future<void> openMenu(
  WidgetTester tester,
  FakeHost fake, {
  SongActionSource source = SongActionSource.other,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AppActions(
          host: fake.host,
          child: SongOverflowButton(song: fakeSong(), source: source),
        ),
      ),
    ),
  );
  await tester.tap(find.byType(SongOverflowButton));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('搜索来源: 菜单不含"不感兴趣"', (tester) async {
    final fake = FakeHost();
    await openMenu(tester, fake, source: SongActionSource.search);
    expect(find.text('不感兴趣'), findsNothing);
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('歌单/专辑/艺人/电台来源同样不含"不感兴趣"', (tester) async {
    for (final source in [
      SongActionSource.playlist,
      SongActionSource.album,
      SongActionSource.artist,
      SongActionSource.radio,
      SongActionSource.other,
    ]) {
      final fake = FakeHost();
      await openMenu(tester, fake, source: source);
      expect(find.text('不感兴趣'), findsNothing, reason: '$source 不应显示不感兴趣');
      // 关掉面板(点屏障), 供下一轮循环复用
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('日推来源: 含"不感兴趣"且点击调用 host.dislike', (tester) async {
    final fake = FakeHost();
    await openMenu(tester, fake, source: SongActionSource.dailyRecommend);
    expect(find.text('不感兴趣'), findsOneWidget);
    await tester.ensureVisible(find.text('不感兴趣'));
    await tester.tap(find.text('不感兴趣'));
    await tester.pumpAndSettle();
    expect(fake.dislikeCalls, 1);
  });

  testWidgets('FM 来源: 含"不感兴趣"且点击调用 host.dislike', (tester) async {
    final fake = FakeHost();
    await openMenu(tester, fake, source: SongActionSource.personalFm);
    expect(find.text('不感兴趣'), findsOneWidget);
    // 统一标题栏占 52px 后, 末项在默认视口折叠线下; 与日推用例同样先 ensureVisible
    await tester.ensureVisible(find.text('不感兴趣'));
    await tester.tap(find.text('不感兴趣'));
    await tester.pumpAndSettle();
    expect(fake.dislikeCalls, 1);
  });

  testWidgets('host.dislike == null: 任何来源都不显示"不感兴趣"', (tester) async {
    for (final source in SongActionSource.values) {
      final fake = FakeHost(withDislike: false);
      await openMenu(tester, fake, source: source);
      expect(
        find.text('不感兴趣'),
        findsNothing,
        reason: 'dislike=null 时 $source 不应显示不感兴趣',
      );
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('300dp + 1.25 字号: 菜单不溢出(日推来源)', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final fake = FakeHost();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: AppActions(
              host: fake.host,
              child: SongOverflowButton(
                song: fakeSong(),
                source: SongActionSource.dailyRecommend,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('下一首播放'), findsOneWidget);
    expect(find.text('不感兴趣'), findsOneWidget);
  });

  testWidgets('推荐页每日推荐条目有行尾"...", 菜单可打开', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = FakeHost();
    await tester.pumpWidget(
      MaterialApp(
        home: AppActions(
          host: fake.host,
          child: Scaffold(
            body: RecommendView(
              loggedIn: true,
              onPlaySongs: (_, _) {},
              onOpenPlaylist: (_) {},
              onOpenPodcast: (_) {},
              onHeartMode: () {},
              onOpenDaily: () {},
              loadDailySongs: () async => [fakeSong(name: '每日一歌')],
              loadDailyPlaylists: () async => [],
              loadPodcasts: () async => [],
              loadFm: () async => [],
              loadStyles: () async => const [],
              loadNewSongs: () async => [],
              loadNewAlbums: () async => [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('更多操作'), findsWidgets);
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    expect(find.text('下一首播放'), findsOneWidget);
  });

  testWidgets('推荐页菜单: 下一首播放/不感兴趣回调被调用', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = FakeHost();
    await tester.pumpWidget(
      MaterialApp(
        home: AppActions(
          host: fake.host,
          child: Scaffold(
            body: RecommendView(
              loggedIn: true,
              onPlaySongs: (_, _) {},
              onOpenPlaylist: (_) {},
              onOpenPodcast: (_) {},
              onHeartMode: () {},
              onOpenDaily: () {},
              loadDailySongs: () async => [fakeSong(name: '每日一歌')],
              loadDailyPlaylists: () async => [],
              loadPodcasts: () async => [],
              loadFm: () async => [],
              loadStyles: () async => const [],
              loadNewSongs: () async => [],
              loadNewAlbums: () async => [],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一首播放'));
    await tester.pumpAndSettle();
    expect(fake.playNextCalls, 1);

    // 再开一次, 点"不感兴趣"(日推来源允许)
    await tester.tap(find.byTooltip('更多操作').first);
    await tester.pumpAndSettle();
    expect(find.text('不感兴趣'), findsOneWidget);
    await tester.tap(find.text('不感兴趣'));
    await tester.pumpAndSettle();
    expect(fake.dislikeCalls, 1);
  });
}
