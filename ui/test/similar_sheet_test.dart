import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/similar_sheet.dart';

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
  testWidgets('相似歌曲面板: 点歌整批起播, 相似歌单可点开', (tester) async {
    List<rust.SongDto>? played;
    int? playedIndex;
    rust.Playlist? opened;

    await tester.pumpWidget(host(Builder(
      builder: (ctx) => TextButton(
        onPressed: () => showSimilarSongs(
          ctx,
          song: song(1, '种子歌'),
          onPlay: (songs, index) {
            played = songs;
            playedIndex = index;
          },
          onOpenPlaylist: (pl) => opened = pl,
          loadSongs: (id, limit) async => [song(2, '相似一'), song(3, '相似二')],
          loadPlaylists: (id, limit) async => [
            rust.Playlist(
              id: BigInt.from(9),
              name: '相似歌单A',
              coverUrl: null,
              trackCount: BigInt.from(20),
              special: false,
            ),
          ],
        ),
        child: const Text('open'),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('和《种子歌》相似'), findsOneWidget);
    expect(find.text('相似一'), findsOneWidget);
    expect(find.text('相似歌单A'), findsOneWidget);

    await tester.tap(find.text('相似二'));
    await tester.pumpAndSettle();
    expect(played?.length, 2);
    expect(playedIndex, 1);

    // 面板关闭后没有内容了(点歌会 pop)
    expect(find.text('相似一'), findsNothing);
    expect(opened, isNull, reason: '点歌不该顺手打开歌单');
  });
}
