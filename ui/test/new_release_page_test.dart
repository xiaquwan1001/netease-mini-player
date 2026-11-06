import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/new_release_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name, String artist) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: artist,
      artistId: BigInt.one,
      album: '专辑',
      albumId: BigInt.one,
      coverUrl: null,
      durationMs: BigInt.from(210000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

rust.AlbumItemDto album(int id, String name) => rust.AlbumItemDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      artist: '歌手',
      trackCount: BigInt.from(3),
    );

rust.HotArtistDto artist(int id, String name, int fans) => rust.HotArtistDto(
      id: BigInt.from(id),
      name: name,
      avatarUrl: null,
      fans: BigInt.from(fans),
    );

void main() {
  testWidgets('新歌页签: 按地区取数, 点歌回调整批列表', (tester) async {
    final areas = <String>[];
    List<rust.SongDto>? played;
    int? playedIndex;
    await tester.pumpWidget(MaterialApp(
      home: NewReleasePage(
        onPlaySongs: (songs, index) {
          played = songs;
          playedIndex = index;
        },
        onOpenAlbum: (_) {},
        onOpenArtist: (_) {},
        loadSongs: (area) async {
          areas.add(area);
          return area == 'zh'
              ? [song(1, '最重要的听众', '法老'), song(2, '我的华北', '刘森')]
              : [song(9, 'Message', 'くるぶっこちゃん')];
        },
        loadAlbums: (area) async => const [],
        loadArtists: () async => const [],
      ),
    ));
    await tester.pumpAndSettle();

    expect(areas, ['all'], reason: '默认取全部地区');
    expect(find.text('Message'), findsOneWidget);

    await tester.tap(find.text('华语'));
    await tester.pumpAndSettle();
    expect(areas, ['all', 'zh']);
    expect(find.text('最重要的听众'), findsOneWidget);

    await tester.tap(find.text('我的华北'));
    await tester.pumpAndSettle();
    expect(played?.length, 2);
    expect(playedIndex, 1);
  });

  testWidgets('新碟页签: 地区切换与点开专辑', (tester) async {
    rust.AlbumItemDto? opened;
    await tester.pumpWidget(MaterialApp(
      home: NewReleasePage(
        onPlaySongs: (_, _) {},
        onOpenAlbum: (a) => opened = a,
        onOpenArtist: (_) {},
        loadSongs: (_) async => const [],
        loadAlbums: (area) async =>
            area == 'jp' ? [album(11, '久石譲 交响组曲')] : [album(10, 'Growth')],
        loadArtists: () async => const [],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('新碟'));
    await tester.pumpAndSettle();
    expect(find.text('Growth'), findsOneWidget);

    await tester.tap(find.text('日本'));
    await tester.pumpAndSettle();
    expect(find.text('久石譲 交响组曲'), findsOneWidget);

    await tester.tap(find.text('久石譲 交响组曲'));
    await tester.pumpAndSettle();
    expect(opened?.name, '久石譲 交响组曲');
  });

  testWidgets('歌手页签: 粉丝数格式化与点开歌手', (tester) async {
    rust.HotArtistDto? opened;
    await tester.pumpWidget(MaterialApp(
      home: NewReleasePage(
        onPlaySongs: (_, _) {},
        onOpenAlbum: (_) {},
        onOpenArtist: (a) => opened = a,
        loadSongs: (_) async => const [],
        loadAlbums: (_) async => const [],
        loadArtists: () async => [
          artist(1, '林俊杰', 16908300),
          artist(2, '小众歌手', 8600),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('歌手'));
    await tester.pumpAndSettle();
    expect(find.text('林俊杰'), findsOneWidget);
    expect(find.text('1691 万粉丝'), findsOneWidget);
    expect(find.text('8600 粉丝'), findsOneWidget);

    await tester.tap(find.text('林俊杰'));
    await tester.pumpAndSettle();
    expect(opened?.name, '林俊杰');
  });

  testWidgets('空结果与失败态', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: NewReleasePage(
        onPlaySongs: (_, _) {},
        onOpenAlbum: (_) {},
        onOpenArtist: (_) {},
        loadSongs: (_) async => throw Exception('[internal] 挂了'),
        loadAlbums: (_) async => const [],
        loadArtists: () async => const [],
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('新碟'));
    await tester.pumpAndSettle();
    expect(find.text('这个地区暂时没有新碟'), findsOneWidget);
  });
}
