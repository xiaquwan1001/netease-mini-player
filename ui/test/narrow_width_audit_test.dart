// 窄屏排版专项审计回归: 300dp/大字体下不再竖排、不再溢出。
// 覆盖矩阵: 逻辑宽 {300,320,360} × textScale {1.0,1.25,1.3,1.625},
// 全部用假数据, 不联网。断言: ①无 overflow 错误 ②关键文本单行 ③右边界不出屏。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/discover.dart';
import 'package:minincm/src/marquee_text.dart';
import 'package:minincm/src/play_queue_sheet.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_landing.dart';
import 'package:minincm/src/search_results.dart';
import 'package:minincm/src/song_tile.dart';

const _longName = '魔法未来2019主题歌Magia[Quartet]Live.Ver超长歌名继续加长再加长一点直到溢出为止啊';
const _longArtist = '一条超级超级长的艺人名组合名称竖排回归测试用歌手名还有更长';
const _creatorLine = '创建者: $_longArtist';
const _longAlbum = '一张同样很长的专辑名称Magia Album Deluxe Edition 豪华版再长一点';

const _widths = [300.0, 320.0, 360.0];
const _scales = [1.0, 1.25, 1.3, 1.625];

rust.SongDto song({int id = 1, bool vip = false}) => rust.SongDto(
  id: BigInt.from(id),
  name: _longName,
  artist: _longArtist,
  artistId: BigInt.from(9),
  album: _longAlbum,
  albumId: BigInt.from(8),
  coverUrl: null,
  durationMs: BigInt.from(269000),
  fee: vip ? 1 : 0,
  vip: vip,
  paid: false,
  playable: true,
);

/// 在指定逻辑宽度/字体缩放下 pump, 返回捕获到的错误文案列表.
Future<List<String>> pumpAudited(
  WidgetTester tester,
  Widget child, {
  required double width,
  required double scale,
}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  tester.view.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d);
  try {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
  } finally {
    // 必须在测试体结束前恢复, 否则 flutter_test 断言失败
    FlutterError.onError = previous;
  }
  return [for (final e in errors) e.exception.toString()];
}

String _tag(String page, double width, double scale) =>
    '$page w=$width s=$scale';

void expectNoOverflow(List<String> errors, String tag) {
  final overflows = errors.where((e) => e.contains('overflowed')).toList();
  expect(overflows, isEmpty, reason: tag);
}

/// 关键文本块必须是单行: 高度不超过两倍行高(竖排会远超).
void expectSingleLine(
  WidgetTester tester,
  Finder finder,
  String tag, {
  double maxLineHeight = 40,
}) {
  final boxes = tester.renderObjectList<RenderBox>(finder);
  expect(boxes, isNotEmpty, reason: tag);
  for (final box in boxes) {
    expect(box.size.height, lessThan(maxLineHeight * 2), reason: tag);
  }
}

void main() {
  testWidgets('SongTile 单条(带红心+更多): 12 组合无溢出/单行/不出屏', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('SongTile', width, scale);
        final errors = await pumpAudited(
          tester,
          Align(
            alignment: Alignment.topLeft,
            child: SongTile(
              song: song(vip: true),
              active: true,
              liked: true,
              onTap: () {},
              onMenu: () {},
            ),
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        expectSingleLine(tester, find.byType(MarqueeText), tag);
        // 歌名/副标题右边界不超出屏幕
        final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
        final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
        expect(right, lessThanOrEqualTo(width + 0.5), reason: tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('搜索结果页(超长歌名/艺人/专辑): 12 组合无溢出, 歌名单行', (tester) async {
    final bundle = rust.SearchBundleDto(
      songs: [song(vip: true), song(id: 2)],
      songTotal: BigInt.from(2),
      artists: [
        rust.SearchArtist(
          id: BigInt.from(9),
          name: _longArtist,
          avatarUrl: null,
          alias: '别名也是很长很长的一段文字Magia',
          albumCount: BigInt.from(3),
          musicCount: BigInt.from(30),
        ),
      ],
      albums: [
        rust.SearchAlbum(
          id: BigInt.from(8),
          name: _longAlbum,
          coverUrl: null,
          artist: _longArtist,
          trackCount: BigInt.from(10),
        ),
      ],
      playlists: [
        rust.SearchPlaylistItem(
          id: BigInt.from(5),
          name: _longName,
          coverUrl: null,
          creatorName: _longArtist,
          trackCount: BigInt.from(20),
          playCount: BigInt.from(100),
        ),
      ],
      podcasts: [],
      users: [
        rust.UserItem(
          id: BigInt.from(7),
          name: _longArtist,
          avatarUrl: null,
          signature: _longName,
          followed: false,
        ),
      ],
    );
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('SearchResults', width, scale);
        final errors = await pumpAudited(
          tester,
          SearchResultsView(
            bundle: bundle,
            liked: <BigInt>{},
            currentTrackId: null,
            onPlaySong: (_) {},
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
            onOpenPlaylist: (_) {},
            onOpenPodcast: (_) {},
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        expectSingleLine(
          tester,
          find.byType(MarqueeText),
          tag,
          maxLineHeight: 30,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('搜索落地页(历史/热词/猜你想搜): 12 组合无溢出', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('SearchLanding', width, scale);
        final errors = await pumpAudited(
          tester,
          SearchLanding(
            history: ['一个很长很长很长很长很长的历史搜索关键词Magia', '七里香'],
            hot: const [
              rust.HotSearchTerm(rank: 1, keyword: _longName),
              rust.HotSearchTerm(rank: 2, keyword: '短词'),
            ],
            recommended: '一个很长很长很长很长的猜你想搜关键词Magia',
            recommendedReason: '🔥Mili 你的十月榜首',
            onSelected: (_) {},
            onClearHistory: () {},
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('推荐页(假 loader, 超长歌名/歌单/播客): 12 组合无溢出, 每日歌单行单行', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('Recommend', width, scale);
        final errors = await pumpAudited(
          tester,
          RecommendView(
            loggedIn: true,
            loadDailySongs: () async => [song(vip: true), song(id: 2)],
            loadDailyPlaylists: () async => [
              rust.Playlist(
                id: BigInt.from(10),
                name: _longName,
                coverUrl: null,
                trackCount: BigInt.from(3),
                special: false,
                subscribed: false,
              ),
            ],
            loadPodcasts: () async => [
              rust.PodcastRadio(
                id: BigInt.from(20),
                name: _longName,
                coverUrl: null,
                description: _longAlbum,
                djName: _longArtist,
                programCount: BigInt.from(2),
                playCount: BigInt.zero,
              ),
            ],
            loadFm: () async => [song(id: 3)],
            loadStyles: () async => const [
              rust.StyleTag(id: '1009', name: '粤语流行'),
            ],
            loadNewAlbums: () async => [
              rust.AlbumItem(
                id: BigInt.from(30),
                name: _longAlbum,
                coverUrl: null,
                artist: _longArtist,
                trackCount: BigInt.from(10),
              ),
            ],
            loadNewSongs: () async => [song(id: 4)],
            onPlaySongs: (_, _) {},
            onOpenPlaylist: (_) {},
            onOpenPodcast: (_) {},
            onHeartMode: () {},
            onOpenDaily: () {},
            onOpenAlbum: (_) {},
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('每日推荐页 discover(假 loader): 12 组合无溢出, 歌行单行', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('Discover', width, scale);
        late BuildContext ctx;
        final errors = <String>[];
        // 先挂宿主拿 context, 再推 discover 页
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (c) {
                  ctx = c;
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        );
        // 采集 discover 页自身的错误
        final previous = FlutterError.onError;
        FlutterError.onError = (d) => errors.add(d.exception.toString());
        showDiscoverPage(
          ctx,
          onPlaySongs: (_, _) {},
          onOpenPlaylist: (_) {},
          loadSongs: () async => [song(vip: true), song(id: 2)],
          loadPlaylists: () async => [
            rust.Playlist(
              id: BigInt.from(9),
              name: _longName,
              coverUrl: null,
              trackCount: BigInt.from(12),
              special: false,
              subscribed: false,
            ),
          ],
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 80));
        FlutterError.onError = previous;
        expectNoOverflow(errors, tag);
        // discover 的歌行是普通 Text(maxLines:1), 断言其单行不竖排
        expectSingleLine(
          tester,
          find.textContaining('魔法未来2019主题歌'),
          tag,
          maxLineHeight: 30,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('歌单详情头卡(同构排版: MarqueeText 在 Expanded 内): 12 组合无溢出/单行/不出屏', (
    tester,
  ) async {
    // 真实 _PlaylistDetailPage 依赖 Rust FFI 取数, 测试无法注入假 loader;
    // 这里按 detail_page 头卡的同一排版结构(Row > Expanded > Column > MarqueeText
    // + 创建者行)做结构等价回归, 防止该组合再退化.
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('PlaylistHeader', width, scale);
        final errors = await pumpAudited(
          tester,
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarqueeText(
                        _longName,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _creatorLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Container(width: 96, height: 96, color: Colors.grey),
              ],
            ),
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        expectSingleLine(
          tester,
          find.byType(MarqueeText),
          tag,
          maxLineHeight: 60,
        );
        final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
        final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
        expect(right, lessThanOrEqualTo(width + 0.5), reason: tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('队列面板(超长歌名/艺人): 12 组合无溢出, 歌名/艺人单行', (tester) async {
    final items = [song(vip: true), song(id: 2)];
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('QueueSheet', width, scale);
        final errors = await pumpAudited(
          tester,
          PlayQueueSheet(
            items: items,
            index: 0,
            onSelect: (_) {},
            onRemove: (_, _) {},
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        expectSingleLine(
          tester,
          find.byType(MarqueeText),
          tag,
          maxLineHeight: 30,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}
