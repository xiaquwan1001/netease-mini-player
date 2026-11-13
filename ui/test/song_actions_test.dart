import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_actions.dart';

/// 假 host: 记录各回调的调用次数(通过 Host 闭包, 不再 implements)
class FakeHost {
  FakeHost({this.loggedIn = true});

  bool loggedIn;

  int toggleLikeCalls = 0;
  int playNextCalls = 0;
  int addToPlaylistCalls = 0;
  int shareCalls = 0;
  int commentsCalls = 0;
  int openArtistCalls = 0;
  int openAlbumCalls = 0;
  int downloadCalls = 0;

  /// 可赋值以便个别用例换成抛异常的实现
  Future<void> Function(rust.SongDto song)? playNextOverride;

  late final SongActionHost host = SongActionHost(
    loggedIn: loggedIn,
    isLiked: (_) => false,
    toggleLike: (_) async => toggleLikeCalls++,
    playNext: (song) async {
      if (playNextOverride != null) return playNextOverride!(song);
      playNextCalls++;
    },
    addToPlaylist: (_) async => addToPlaylistCalls++,
    share: (_) async => shareCalls++,
    comments: (_) async => commentsCalls++,
    openArtist: (_) async => openArtistCalls++,
    openAlbum: (_) async => openAlbumCalls++,
    download: (_) async => downloadCalls++,
  );
}

rust.SongDto fakeSong({BigInt? artistId, BigInt? albumId}) => rust.SongDto(
  id: BigInt.from(42),
  name: '测试歌曲',
  artist: '测试艺人',
  artistId: artistId ?? BigInt.one,
  album: '测试专辑',
  albumId: albumId ?? BigInt.one,
  durationMs: BigInt.from(200000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

void main() {
  Widget app(
    FakeHost fake,
    rust.SongDto song, {
    SongActionSource source = SongActionSource.other,
  }) => MaterialApp(
    home: Scaffold(
      body: AppActions(
        host: fake.host,
        child: SongOverflowButton(song: song, source: source),
      ),
    ),
  );

  testWidgets('点击 ... 打开动作面板并展示全部菜单项', (tester) async {
    final host = FakeHost();
    await tester.pumpWidget(app(host, fakeSong()));
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();

    expect(find.text('下一首播放'), findsOneWidget);
    expect(find.text('喜欢'), findsOneWidget);
    expect(find.text('收藏到歌单'), findsOneWidget);
    expect(find.text('分享'), findsOneWidget);
    expect(find.text('查看评论'), findsOneWidget);
    expect(find.text('艺人信息'), findsOneWidget);
    expect(find.text('专辑信息'), findsOneWidget);
    expect(find.text('下载'), findsOneWidget);
  });

  testWidgets('点下一首播放关闭面板并计数 +1', (tester) async {
    final host = FakeHost();
    await tester.pumpWidget(app(host, fakeSong()));
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一首播放'));
    await tester.pumpAndSettle();

    expect(host.playNextCalls, 1);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('artistId/albumId 为 0 时艺人/专辑入口禁用', (tester) async {
    final host = FakeHost();
    final song = fakeSong(artistId: BigInt.zero, albumId: BigInt.zero);
    await tester.pumpWidget(app(host, song));
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();

    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '艺人信息')).onTap,
      isNull,
    );
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, '专辑信息')).onTap,
      isNull,
    );

    await tester.ensureVisible(find.text('艺人信息'));
    await tester.tap(find.text('艺人信息'));
    await tester.pumpAndSettle();
    expect(host.openArtistCalls, 0);
  });

  testWidgets('回调抛异常时提示 操作失败', (tester) async {
    final host = FakeHost();
    var failedCalls = 0;
    host.playNextOverride = (song) async {
      failedCalls++;
      throw StateError('网络异常');
    };
    await tester.pumpWidget(app(host, fakeSong()));
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();

    await tester.tap(find.text('下一首播放'));
    await tester.pumpAndSettle();

    expect(failedCalls, 1);
    expect(find.textContaining('操作失败'), findsOneWidget);
  });

  testWidgets('挂了"不感兴趣"回调才显示该菜单项', (tester) async {
    var disliked = 0;
    final host = SongActionHost(
      loggedIn: true,
      isLiked: (_) => false,
      toggleLike: (_) async {},
      playNext: (_) async {},
      addToPlaylist: (_) async {},
      share: (_) async {},
      comments: (_) async {},
      openArtist: (_) async {},
      openAlbum: (_) async {},
      download: (_) async {},
      dislike: (_) async => disliked++,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppActions(
            host: host,
            // "不感兴趣"只在日推/FM 来源显示
            child: SongOverflowButton(
              song: fakeSong(),
              source: SongActionSource.dailyRecommend,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();
    expect(find.text('不感兴趣'), findsOneWidget);
    // 统一标题栏占 52px 后, 末项在默认视口折叠线下; 与日推用例同样先 ensureVisible
    await tester.ensureVisible(find.text('不感兴趣'));
    await tester.tap(find.text('不感兴趣'));
    await tester.pumpAndSettle();
    expect(disliked, 1);
  });

  testWidgets('没有回调时不显示"不感兴趣"与"相似歌曲"', (tester) async {
    await tester.pumpWidget(app(FakeHost(), fakeSong()));
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();
    expect(find.text('不感兴趣'), findsNothing);
    expect(find.text('相似歌曲'), findsNothing);
  });

  testWidgets('未挂 AppActions 时按钮渲染为空', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SongOverflowButton(song: fakeSong())),
      ),
    );
    expect(find.byType(SongOverflowButton), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fake = FakeHost();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: AppActions(
            host: fake.host,
            child: SongOverflowButton(song: fakeSong()),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SongOverflowButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
