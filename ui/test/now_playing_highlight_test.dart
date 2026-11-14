import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/now_playing.dart';
import 'package:minincm/src/ranking_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_tile.dart';

/// 回归 2026-11-14 用户新需求:
/// 「当前播放推荐歌曲的时候, 在完整日推歌单里面, 正在播放的歌曲没有被高亮标记;
///   需要检查所有可能的位置, 保证一首歌(播客)会出现在正在交互的歌单(播客)里」
///
/// 做法是全局单一样本 [nowPlayingSongId] + 行组件 [NowPlayingHighlight]:
/// 这里钉住"行自己不需要传 currentTrackId 也能高亮, 且切歌实时跟随"。
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

Future<void> pumpFrames(WidgetTester tester, {int frames = 6}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  tearDown(() => nowPlayingSongId.value = null);

  testWidgets('歌曲行不传 active 也读全局"正在播放"', (tester) async {
    nowPlayingSongId.value = BigInt.from(2);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final s in [song(1, '晴天'), song(2, '七里香')])
                SongTile(song: s, liked: false, onTap: () {}),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    ListTile tileOf(String name) => tester.widget<ListTile>(
      find.ancestor(of: find.text(name), matching: find.byType(ListTile)).first,
    );
    expect(tileOf('七里香').selected, isTrue, reason: '正在播放的那首要高亮');
    expect(tileOf('晴天').selected, isFalse);

    // 切歌后高亮实时跟随(不需要重建整页)
    nowPlayingSongId.value = BigInt.from(1);
    await tester.pumpAndSettle();
    expect(tileOf('晴天').selected, isTrue);
    expect(tileOf('七里香').selected, isFalse);
  });

  testWidgets('完整日推歌单里正在播放的歌曲有标记(序号换成喇叭)', (tester) async {
    nowPlayingSongId.value = BigInt.from(2);
    await tester.pumpWidget(
      MaterialApp(
        home: DailyRecommendPage(
          loadSongs: () async => [song(1, '晴天'), song(2, '七里香')],
          loadPlaylists: () async => const <rust.Playlist>[],
          loadHistoryDates: () async => const <String>[],
          loadHistorySongs: (_) async => const <rust.SongDto>[],
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
        ),
      ),
    );
    await pumpFrames(tester);

    // 被选中的那一行是 ListTile.selected; 且序号列换成了喇叭图标
    final tile = tester.widget<ListTile>(
      find
          .ancestor(of: find.text('七里香'), matching: find.byType(ListTile))
          .first,
    );
    expect(tile.selected, isTrue);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });

  testWidgets('听歌排行里正在播放的歌曲也有标记', (tester) async {
    nowPlayingSongId.value = BigInt.from(7);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayRankingView(
            onPlaySongs: (_, _) {},
            load: (period) async => [
              rust.PlayRankEntryDto(
                song: song(8, '最常听'),
                playCount: BigInt.from(3),
                score: BigInt.from(30),
              ),
              rust.PlayRankEntryDto(
                song: song(7, '最近常听'),
                playCount: BigInt.from(2),
                score: BigInt.from(20),
              ),
            ],
          ),
        ),
      ),
    );
    await pumpFrames(tester);

    final tile = tester.widget<ListTile>(
      find
          .ancestor(of: find.text('最近常听'), matching: find.byType(ListTile))
          .first,
    );
    expect(tile.selected, isTrue);
    expect(find.byIcon(Icons.volume_up), findsOneWidget);
  });
}
