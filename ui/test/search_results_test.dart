import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_results.dart';
import 'package:minincm/src/user_nav.dart';

void main() {
  testWidgets('综合搜索结果: 分类横向排列(单曲/艺人/专辑/歌单/播客), 切换后看对应内容', (tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    rust.SearchAlbum? openedAlbum;

    final song = rust.SongDto(
      id: BigInt.from(1),
      name: '测试歌曲',
      artist: '测试艺人',
      artistId: BigInt.from(9),
      album: '测试专辑',
      albumId: BigInt.from(8),
      coverUrl: null,
      durationMs: BigInt.from(200000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

    final bundle = rust.SearchBundleDto(
      songs: [song, song],
      songTotal: BigInt.from(2),
      artists: [
        rust.SearchArtist(
          id: BigInt.from(9),
          name: '测试艺人',
          avatarUrl: null,
          alias: '',
          albumCount: BigInt.from(3),
          musicCount: BigInt.from(30),
        ),
      ],
      albums: [
        rust.SearchAlbum(
          id: BigInt.from(8),
          name: '测试专辑',
          coverUrl: null,
          artist: '测试艺人',
          trackCount: BigInt.from(10),
        ),
      ],
      playlists: [
        rust.SearchPlaylistItem(
          id: BigInt.from(5),
          name: '测试歌单',
          coverUrl: null,
          creatorName: '创建者',
          trackCount: BigInt.from(20),
          playCount: BigInt.from(100),
        ),
      ],
      podcasts: [
        rust.SearchPodcast(
          id: BigInt.from(6),
          name: '测试播客',
          coverUrl: null,
          djName: '主播',
          programCount: BigInt.from(7),
          playCount: BigInt.from(200),
        ),
      ],
      users: [
        rust.UserItem(
          id: BigInt.from(7),
          name: '测试用户',
          avatarUrl: null,
          signature: '签名',
          followed: false,
        ),
      ],
      mvs: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchResultsView(
            bundle: bundle,
            liked: <BigInt>{},
            currentTrackId: null,
            onPlaySong: (_) {},
            onOpenArtist: (_) {},
            onOpenAlbum: (a) => openedAlbum = a,
            onOpenPlaylist: (_) {},
            onOpenPodcast: (_) {},
          ),
        ),
      ),
    );

    // 六个分类 chip 同时可见(Wrap 换行, 不再横向滚动把后两个藏起来)
    for (final label in ['单曲', '艺人', '专辑', '歌单', '播客', '用户']) {
      expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
    }
    // 默认显示「单曲」分类: 歌曲行在, 专辑卡片还没渲染
    expect(find.text('测试歌曲'), findsWidgets);
    expect(find.text('测试专辑'), findsNothing);

    // 点「专辑」chip 切到专辑分类, 点卡片触发回调
    await tester.tap(find.widgetWithText(ChoiceChip, '专辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试专辑'));
    expect(openedAlbum, isNotNull);
    expect(openedAlbum!.id, BigInt.from(8));

    // 点「艺人」chip 能看到艺人卡片
    await tester.tap(find.widgetWithText(ChoiceChip, '艺人'));
    await tester.pumpAndSettle();
    expect(find.text('测试艺人'), findsWidgets);
  });

  testWidgets('300dp + 1.25 字号不溢出(五分区长文案)', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: SearchResultsView(
              bundle: rust.SearchBundleDto(
                songs: [
                  rust.SongDto(
                    id: BigInt.from(1),
                    name: '一首名字特别特别长的歌曲用于小屏回归测试',
                    artist: '一个名字特别特别长的艺人用于小屏回归测试',
                    artistId: BigInt.from(9),
                    album: '一张名字特别特别长的专辑用于小屏回归测试',
                    albumId: BigInt.from(8),
                    coverUrl: null,
                    durationMs: BigInt.from(200000),
                    fee: 0,
                    vip: false,
                    paid: false,
                    playable: true,
                  ),
                ],
                songTotal: BigInt.one,
                artists: [
                  rust.SearchArtist(
                    id: BigInt.from(9),
                    name: '一个名字特别特别长的艺人用于小屏回归测试',
                    avatarUrl: null,
                    alias: '',
                    albumCount: BigInt.from(3),
                    musicCount: BigInt.from(30),
                  ),
                ],
                albums: [
                  rust.SearchAlbum(
                    id: BigInt.from(8),
                    name: '一张名字特别特别长的专辑用于小屏回归测试',
                    coverUrl: null,
                    artist: '测试艺人',
                    trackCount: BigInt.from(10),
                  ),
                ],
                playlists: [
                  rust.SearchPlaylistItem(
                    id: BigInt.from(5),
                    name: '一个名字特别特别长的歌单用于小屏回归测试',
                    coverUrl: null,
                    creatorName: '创建者',
                    trackCount: BigInt.from(20),
                    playCount: BigInt.from(100),
                  ),
                ],
                podcasts: [
                  rust.SearchPodcast(
                    id: BigInt.from(6),
                    name: '一个名字特别特别长的播客用于小屏回归测试',
                    coverUrl: null,
                    djName: '主播',
                    programCount: BigInt.from(7),
                    playCount: BigInt.from(200),
                  ),
                ],
                users: const [],
                mvs: const [],
              ),
              liked: <BigInt>{},
              currentTrackId: null,
              onPlaySong: (_) {},
              onOpenArtist: (_) {},
              onOpenAlbum: (_) {},
              onOpenPlaylist: (_) {},
              onOpenPodcast: (_) {},
            ),
          ),
        ),
      ),
    );
    // 长歌名在窄屏会进走马灯(持续动画), 不能 pumpAndSettle, 分步 pump 即可。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(ChoiceChip, '单曲'), findsOneWidget);
  });

  testWidgets('全空时显示空提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchResultsView(
            bundle: rust.SearchBundleDto(
              songs: [],
              songTotal: BigInt.zero,
              artists: [],
              albums: [],
              playlists: [],
              podcasts: [],
              users: const [],
              mvs: const [],
            ),
            liked: const {},
            currentTrackId: null,
            onPlaySong: (_) {},
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
            onOpenPlaylist: (_) {},
            onOpenPodcast: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('没有找到相关内容'), findsOneWidget);
  });

  testWidgets('用户分类: 点卡片进个人主页(统一走 UserNav)', (tester) async {
    BigInt? opened;
    final prev = UserNav.opener;
    UserNav.opener =
        (BuildContext context, BigInt userId, {String? nickname}) async {
          opened = userId;
        };
    addTearDown(() => UserNav.opener = prev);

    final bundle = rust.SearchBundleDto(
      songs: const [],
      songTotal: BigInt.zero,
      artists: const [],
      albums: const [],
      playlists: const [],
      podcasts: const [],
      users: [
        rust.UserItem(
          id: BigInt.from(42),
          name: '小明',
          avatarUrl: null,
          signature: 'hi',
          followed: false,
        ),
      ],
      mvs: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchResultsView(
            bundle: bundle,
            liked: const <BigInt>{},
            currentTrackId: null,
            onPlaySong: (_) {},
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
            onOpenPlaylist: (_) {},
            onOpenPodcast: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, '用户'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, '用户'));
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsOneWidget);

    await tester.tap(find.text('小明'));
    await tester.pumpAndSettle();
    expect(opened, BigInt.from(42));
  });
}
