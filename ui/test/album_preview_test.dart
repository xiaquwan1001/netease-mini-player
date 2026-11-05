import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/album_preview.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '周杰伦',
      artistId: BigInt.one,
      album: '叶惠美',
      albumId: BigInt.from(9),
      coverUrl: null,
      durationMs: BigInt.from(1000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

rust.AlbumDetailDto album() => rust.AlbumDetailDto(
      id: BigInt.from(9),
      name: '叶惠美',
      coverUrl: null,
      artist: '周杰伦',
      description: '经典专辑',
      songs: [song(1, '以父之名'), song(2, '晴天')],
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
  testWidgets('专辑预览: 展示封面/信息/曲目, 点曲目回调整张专辑', (tester) async {
    List<rust.SongDto>? played;
    int? playedIndex;
    await tester.pumpWidget(host(() {
      showAlbumPreview(
        tester.element(find.text('open')),
        albumId: BigInt.from(9),
        onPlay: (songs, index) {
          played = songs;
          playedIndex = index;
        },
        loadAlbum: (_) async => album(),
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('叶惠美'), findsOneWidget);
    expect(find.text('周杰伦'), findsWidgets);
    expect(find.text('共 2 首'), findsOneWidget);
    expect(find.text('以父之名'), findsOneWidget);

    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();
    expect(played?.length, 2);
    expect(playedIndex, 1);
  });

  testWidgets('专辑预览: albumId 为 0 时只显示封面标题(无网络请求)', (tester) async {
    var called = false;
    await tester.pumpWidget(host(() {
      showAlbumPreview(
        tester.element(find.text('open')),
        albumId: BigInt.zero,
        albumName: '未知专辑',
        onPlay: (_, _) {},
        loadAlbum: (_) async {
          called = true;
          return album();
        },
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('未知专辑'), findsOneWidget);
    expect(called, false);
  });
}
