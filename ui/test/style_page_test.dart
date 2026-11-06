import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/style_page.dart';

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手',
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

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('曲风详情页展示歌单与歌曲', (tester) async {
    List<rust.SongDto>? played;
    rust.PlaylistDto? opened;

    await tester.pumpWidget(host(StyleDetailView(
      tag: rust.StyleTagDto(
        id: '1009',
        name: '粤语流行',
        songCount: BigInt.from(2046),
      ),
      loadSongs: (_) async => [song(1, '风格单曲')],
      loadPlaylists: (_) async => [
        rust.PlaylistDto(
          id: BigInt.from(22),
          name: '粤语流行趋势',
          coverUrl: null,
          trackCount: BigInt.from(200),
          special: false,
        ),
      ],
      onPlaySongs: (songs, index) => played = songs,
      onOpenPlaylist: (pl) => opened = pl,
    )));
    await tester.pumpAndSettle();

    expect(find.text('粤语流行'), findsOneWidget);
    expect(find.text('共 2046 首'), findsOneWidget);
    expect(find.text('粤语流行趋势'), findsOneWidget);

    await tester.tap(find.text('粤语流行趋势'));
    expect(opened?.id, BigInt.from(22));

    await tester.tap(find.text('风格单曲'));
    expect(played?.single.name, '风格单曲');
  });
}
