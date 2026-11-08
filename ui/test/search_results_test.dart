import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_results.dart';

void main() {
  testWidgets('综合搜索结果渲染五个分区并触发回调', (tester) async {
    // 五个分区在小屏需要滚动才构建, 测试直接给个高一点的画布
    tester.view.physicalSize = const Size(1000, 2800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    rust.SearchAlbum? openedAlbum;

    final song = rust.SongDto(
      id: BigInt.from(1),
      name: '测试歌曲',
      artist: '测试歌手',
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
          name: '测试歌手',
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
          artist: '测试歌手',
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

    // 五个分区标题都在
    expect(find.text('单曲'), findsOneWidget);
    expect(find.text('歌手'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('播客'), findsOneWidget);

    // 歌手名出现(分区卡片)
    expect(find.text('测试歌手'), findsWidgets);

    // 点专辑卡片触发回调
    await tester.tap(find.text('测试专辑'));
    expect(openedAlbum, isNotNull);
    expect(openedAlbum!.id, BigInt.from(8));
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
}
