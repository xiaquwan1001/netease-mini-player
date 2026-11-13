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
    rust.Playlist? opened;

    await tester.pumpWidget(
      host(
        StyleDetailView(
          tag: rust.StyleTag(
            id: '1009',
            name: '粤语流行',
            songCount: BigInt.from(2046),
          ),
          loadSongs: (_) async => [song(1, '风格单曲')],
          loadPlaylists: (_) async => [
            rust.Playlist(
              id: BigInt.from(22),
              name: '粤语流行趋势',
              coverUrl: null,
              trackCount: BigInt.from(200),
              special: false,
            ),
          ],
          onPlaySongs: (songs, index) => played = songs,
          onOpenPlaylist: (pl) => opened = pl,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('粤语流行'), findsOneWidget);
    expect(find.text('共 2046 首'), findsOneWidget);
    expect(find.text('粤语流行趋势'), findsOneWidget);

    await tester.tap(find.text('粤语流行趋势'));
    expect(opened?.id, BigInt.from(22));

    await tester.tap(find.text('风格单曲'));
    expect(played?.single.name, '风格单曲');
  });

  testWidgets('空态: 风格歌单/歌曲为空时给出占位提示', (tester) async {
    await tester.pumpWidget(
      host(
        StyleDetailView(
          tag: rust.StyleTag(id: '1', name: '冷门风格', songCount: null),
          loadSongs: (_) async => const [],
          loadPlaylists: (_) async => const [],
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('这个风格暂时没有歌单'), findsOneWidget);
    expect(find.text('这个风格暂时没有歌曲'), findsOneWidget);
  });

  testWidgets('加载失败: friendlyError + 重试, 重试后出数据', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        StyleDetailView(
          tag: rust.StyleTag(id: '1', name: '失败风格', songCount: null),
          loadSongs: (_) async {
            attempts++;
            if (attempts <= 3) throw Exception('[network] reset');
            return [song(1, '重试后的风格歌')];
          },
          loadPlaylists: (_) async => const [],
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('网络不稳定'), findsOneWidget);
    expect(find.text('重试'), findsWidgets);

    await tester.tap(find.text('重试').first);
    await tester.pumpAndSettle();
    expect(find.text('重试后的风格歌'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: StyleDetailView(
              tag: rust.StyleTag(
                id: '1009',
                name: '一个名字特别特别长的曲风用于小屏回归测试',
                songCount: BigInt.from(2046),
              ),
              loadSongs: (_) async => [song(1, '小屏风格歌')],
              loadPlaylists: (_) async => [
                rust.Playlist(
                  id: BigInt.from(22),
                  name: '小屏上的一个很长很长很长很长很长名称的歌单',
                  coverUrl: null,
                  trackCount: BigInt.from(200),
                  special: false,
                ),
              ],
              onPlaySongs: (_, _) {},
              onOpenPlaylist: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('小屏风格歌'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
