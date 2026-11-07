import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/new_release_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.AlbumItemDto album(int id, String name) => rust.AlbumItemDto(
      id: BigInt.from(id),
      name: name,
      coverUrl: null,
      artist: '歌手A',
      trackCount: BigInt.from(10),
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('精选新碟页签: 网格渲染 + 点击回调', (tester) async {
    rust.AlbumItemDto? opened;
    await tester.pumpWidget(host(NewReleasePage(
      onPlaySongs: (_, __) {},
      onOpenAlbum: (a) => opened = a,
      onOpenArtist: (_) {},
      loadNewestAlbums: () async => [album(1, '精选新碟A'), album(2, '精选新碟B')],
    )));
    await tester.pumpAndSettle();

    // 默认在新歌页签, 切到精选新碟
    expect(find.text('精选新碟'), findsOneWidget);
    await tester.tap(find.text('精选新碟'));
    await tester.pumpAndSettle();

    expect(find.text('精选新碟A'), findsOneWidget);
    expect(find.text('精选新碟B'), findsOneWidget);
    expect(find.text('歌手A'), findsNWidgets(2));

    await tester.tap(find.text('精选新碟A'));
    expect(opened?.id, BigInt.one);
  });

  testWidgets('新歌页签: 错误重试 + 空态文案', (tester) async {
    var fail = true;
    await tester.pumpWidget(host(NewReleasePage(
      onPlaySongs: (_, __) {},
      onOpenAlbum: (_) {},
      onOpenArtist: (_) {},
      loadSongs: (area) async {
        if (fail) throw Exception('[network] boom');
        return <rust.SongDto>[];
      },
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('这个地区暂时没有新歌'), findsOneWidget);
  });

  testWidgets('精选新碟: 空态与错误重试', (tester) async {
    var fail = true;
    await tester.pumpWidget(host(NewReleasePage(
      onPlaySongs: (_, __) {},
      onOpenAlbum: (_) {},
      onOpenArtist: (_) {},
      loadNewestAlbums: () async {
        if (fail) throw Exception('[network] boom');
        return <rust.AlbumItemDto>[];
      },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('精选新碟'));
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('暂时没有精选新碟'), findsOneWidget);
  });
}
