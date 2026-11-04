import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手',
      album: '专辑',
      albumId: BigInt.one,
      coverUrl: null,
      durationMs: BigInt.from(1000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

rust.PlaylistDto playlist(int id, String name, int count) => rust.PlaylistDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      trackCount: BigInt.from(count),
      special: false,
    );

Widget host(VoidCallback onTap) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: onTap,
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('每日推荐: 歌曲列表可点, 回调整批曲目与下标', (tester) async {
    List<rust.SongDto>? played;
    int? playedIndex;
    await tester.pumpWidget(host(() {
      showDiscoverSheet(
        tester.element(find.text('open')),
        onPlaySongs: (songs, index) {
          played = songs;
          playedIndex = index;
        },
        onOpenPlaylist: (_) {},
        loadSongs: () async => [song(1, '晴天'), song(2, '七里香')],
        loadPlaylists: () async => [playlist(9, '推荐歌单', 12)],
      );
    }));
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
    rust.PlaylistDto? opened;
    await tester.pumpWidget(host(() {
      showDiscoverSheet(
        tester.element(find.text('open')),
        onPlaySongs: (_, _) {},
        onOpenPlaylist: (pl) => opened = pl,
        loadSongs: () async => [song(1, '晴天')],
        loadPlaylists: () async => [playlist(9, '推荐歌单', 12)],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('推荐歌单').last);
    await tester.pumpAndSettle();
    // 歌单名称 + 曲目数
    expect(find.text('12 首'), findsOneWidget);
    await tester.tap(find.text('推荐歌单').last);
    await tester.pumpAndSettle();
    expect(opened?.id, BigInt.from(9));
  });

  testWidgets('每日推荐: 加载失败展示错误与重试', (tester) async {
    await tester.pumpWidget(host(() {
      showDiscoverSheet(
        tester.element(find.text('open')),
        onPlaySongs: (_, _) {},
        onOpenPlaylist: (_) {},
        loadSongs: () async => throw Exception('[network] boom'),
        loadPlaylists: () async => const [],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('最近听过: 列表可点并回调', (tester) async {
    List<rust.SongDto>? played;
    await tester.pumpWidget(host(() {
      showRecentSheet(
        tester.element(find.text('open')),
        onPlay: (songs, index) => played = songs,
        loadRecent: () async => [song(3, '最近一首')],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('最近听过'), findsOneWidget);
    await tester.tap(find.text('最近一首'));
    await tester.pumpAndSettle();
    expect(played?.single.name, '最近一首');
  });
}
