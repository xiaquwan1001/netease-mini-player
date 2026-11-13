import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/my_collections_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: '艺人',
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
  trackCount: BigInt.from(5),
  special: false,
  subscribed: false,
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

rust.AlbumItem album(int id, String name) => rust.AlbumItem(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  artist: '艺人',
  trackCount: BigInt.from(10),
);

Widget pushHost(String label, VoidCallback onTap) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (ctx) => TextButton(onPressed: onTap, child: Text(label)),
    ),
  ),
);

Widget buildMine({required int Function() onLikedLoad}) => MineView(
  loggedIn: true,
  onLogin: () {},
  onOpenAccounts: () {},
  onPlaySongs: (_, _) {},
  onOpenPlaylist: (_) {},
  onOpenPodcast: (_) {},
  onOpenAlbum: (_) {},
  onOpenRecent: () {},
  onOpenFollows: () async {},
  onOpenFolloweds: () async {},
  onOpenLiked: () {},
  loadLiked: () async {
    onLikedLoad();
    return [song(1, '喜欢的歌')];
  },
  loadPlaylists: () async => [playlist(2, '收藏歌单A'), playlist(3, '收藏歌单B')],
  loadPodcasts: () async => [radio(4, '收藏播客A')],
  loadAlbums: () async => [album(5, '收藏专辑A')],
  loadRecent: () async => [song(6, '最近听的歌')],
  loadRanking: (_) async => const [],
);

void main() {
  testWidgets('收藏歌单"查看全部"打开整页列表, 点条目回调', (tester) async {
    rust.Playlist? opened;
    await tester.pumpWidget(
      pushHost('open', () {
        showMyPlaylistsPage(
          tester.element(find.text('open')),
          load: () async => [playlist(2, '收藏歌单A'), playlist(3, '收藏歌单B')],
          onOpen: (p) => opened = p,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('收藏的歌单'), findsOneWidget);
    expect(find.text('收藏歌单A'), findsOneWidget);
    expect(find.text('收藏歌单B'), findsOneWidget);

    await tester.tap(find.text('收藏歌单B'));
    expect(opened?.id, BigInt.from(3));
  });

  testWidgets('收藏播客"查看全部"打开整页列表', (tester) async {
    rust.PodcastRadio? opened;
    await tester.pumpWidget(
      pushHost('open', () {
        showMyPodcastsPage(
          tester.element(find.text('open')),
          load: () async => [radio(4, '收藏播客A')],
          onOpen: (r) => opened = r,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('收藏的播客'), findsOneWidget);
    expect(find.text('收藏播客A'), findsOneWidget);
    await tester.tap(find.text('收藏播客A'));
    expect(opened?.id, BigInt.from(4));
  });

  testWidgets('收藏专辑"查看全部"打开整页列表', (tester) async {
    rust.AlbumItem? opened;
    await tester.pumpWidget(
      pushHost('open', () {
        showMyAlbumsPage(
          tester.element(find.text('open')),
          load: () async => [album(5, '收藏专辑A')],
          onOpen: (a) => opened = a,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('收藏的专辑'), findsOneWidget);
    expect(find.text('收藏专辑A'), findsOneWidget);
    await tester.tap(find.text('收藏专辑A'));
    expect(opened?.id, BigInt.from(5));
  });

  testWidgets('区块滚出视野再回来不重新加载(修"上下抽搐")', (tester) async {
    var likedLoads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: buildMine(onLikedLoad: () => likedLoads++)),
      ),
    );
    await tester.pumpAndSettle();
    expect(likedLoads, 1);

    // 滚到下方让"我喜欢的音乐"离开视口(旧实现会 dispose + 重新 initState)
    await tester.drag(find.byType(ListView).first, const Offset(0, -1600));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, 1600));
    await tester.pumpAndSettle();

    expect(find.text('喜欢的歌'), findsOneWidget);
    expect(likedLoads, 1, reason: '区块回到视野应复用已加载数据, 不再转圈');
  });

  testWidgets('三个收藏区块都有"查看全部"入口, 点开是二级整页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: buildMine(onLikedLoad: () => 0)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView).first, const Offset(0, -900));
    await tester.pumpAndSettle();

    // 我喜欢 / 收藏歌单 / 收藏播客 / 收藏专辑 / 最近听过 都应有入口
    // (各二级整页的打开行为由上面三个用例直接覆盖)
    expect(find.widgetWithText(TextButton, '查看全部'), findsAtLeastNWidgets(4));
    expect(find.text('收藏的播客'), findsOneWidget);
    expect(find.text('收藏的专辑'), findsOneWidget);
  });
}
