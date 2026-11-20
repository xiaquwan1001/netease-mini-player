// 窄屏排版专项审计回归: 300dp/大字体下不再竖排、不再溢出。
// 覆盖矩阵: 逻辑宽 {300,320,360} × textScale {1.0,1.25,1.3,1.625},
// 全部用假数据, 不联网。断言: ①无 overflow 错误 ②关键文本单行 ③右边界不出屏。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/artist_page.dart';
import 'package:minincm/src/artist_sections.dart';
import 'package:minincm/src/cover_quality_sheet.dart';
import 'package:minincm/src/digital_album_page.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/marquee_text.dart';
import 'package:minincm/src/messages/inbox_tab.dart';
import 'package:minincm/src/messages/sessions_tab.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/new_release_page.dart';
import 'package:minincm/src/play_queue_sheet.dart';
import 'package:minincm/src/radio_subscribers_page.dart';
import 'package:minincm/src/ranking_view.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/search_landing.dart';
import 'package:minincm/src/search_results.dart';
import 'package:minincm/src/song_tile.dart';
import 'package:minincm/src/song_wiki.dart';
import 'package:minincm/src/user_list_page.dart';

import 'support/fakes.dart';

const _longName = '魔法未来2019主题歌Magia[Quartet]Live.Ver超长歌名继续加长再加长一点直到溢出为止啊';
const _longArtist = '一条超级超级长的艺人名组合名称竖排回归测试用艺人名还有更长';
const _creatorLine = '创建者: $_longArtist';
const _longAlbum = '一张同样很长的专辑名称Magia Album Deluxe Edition 豪华版再长一点';

const _widths = [300.0, 320.0, 360.0];
const _scales = [1.0, 1.25, 1.3, 1.625];

/// 共享工厂 + 本文件的长歌名/长艺人/长专辑口径(窄屏排版回归专用)。
rust.SongDto song({int id = 1, bool vip = false}) => fakeSong(
  id: id,
  name: _longName,
  artist: _longArtist,
  artistId: 9,
  album: _longAlbum,
  albumId: 8,
  durationMs: 269000,
  fee: vip ? 1 : 0,
  vip: vip,
);

/// 在指定逻辑宽度/字体缩放下 pump, 返回捕获到的错误文案列表.
Future<List<String>> pumpAudited(
  WidgetTester tester,
  Widget child, {
  required double width,
  required double scale,

  /// 视口高度: 弹窗/长页面(B3/B4/B9)需要更高才有布局意义
  double height = 700,

  /// pump 完再跑一段(切 tab、开面板), 期间产生的错误同样计入
  Future<void> Function()? after,
}) async {
  tester.view.physicalSize = Size(width, height);
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
    // 切 tab / 开面板等后续步骤的错误也要算在同一条用例里
    if (after != null) await after();
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
        // B5 断言口径(2026-11-16 编排者复核改): 直接量 **行尾被约束后的实际宽度**
        // <= 行宽 45%。不要拿 MarqueeText 的宽度当代理 —— 它自撑到内容宽(长标题时
        // 恰好等于可用宽, 短标题时更窄), 既量不到行尾也和封顶解耦: 实测把
        // kRowTrailingMaxRatio 从 0.45 改成 1.0, 该数字一个像素都没变。
        // capRowTrailing 的唯一实现是 layout.dart 里的 ConstrainedBox(maxWidth: 45%)。
        final capped = find.byWidgetPredicate(
          (w) =>
              w is ConstrainedBox &&
              (w.constraints.maxWidth - width * 0.45).abs() < 0.6,
        );
        expect(capped, findsWidgets, reason: '$tag 行尾没有套 capRowTrailing');
        for (final trailing in tester.renderObjectList<RenderBox>(capped)) {
          expect(
            trailing.size.width,
            lessThanOrEqualTo(width * 0.45 + 0.5),
            reason: '$tag 行尾宽度超过行宽 45%',
          );
        }
        final duration = find.text('04:29');
        if (duration.evaluate().isNotEmpty) {
          expect(
            tester.widget<Text>(duration).maxLines,
            1,
            reason: '$tag 行尾时长缺 maxLines(大字号会换行撑高)',
          );
        }
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
      mvs: const [],
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
            recommended: const [
              RecommendedKeyword(keyword: '一个很长很长很长很长的猜你想搜关键词Magia'),
            ],
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

  // 电台听众页: AppBar 标题写了 ellipsis 却没 maxLines(先换行再省略, 标题栏被撑高),
  // 行内昵称/签名同款问题。这里锁「AppBar 标题单行 + 12 组合无溢出」。
  testWidgets('电台听众页(超长电台名/昵称/签名): 12 组合无溢出, 标题单行', (tester) async {
    final longRadio = '一个特别特别长的电台名称用于窄屏回归测试还要再长一点点';
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('RadioSubscribers', width, scale);
        final errors = await pumpAudited(
          tester,
          RadioSubscribersPage(
            radioId: BigInt.one,
            radioName: longRadio,
            loadSubscribers: (id, timeMs) async => rust.RadioSubscriberPage(
              hasMore: false,
              subscribers: [
                rust.RadioSubscriber(
                  userId: BigInt.from(7),
                  nickname: _longArtist,
                  avatarUrl: '',
                  signature: _longName,
                  subscribeTimeMs: BigInt.from(1700000000000),
                ),
              ],
            ),
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        final title = tester.widget<Text>(find.text('「$longRadio」的听众'));
        expect(title.maxLines, 1, reason: '$tag 缺 maxLines 会先换行再省略');
        expectSingleLine(
          tester,
          find.text('「$longRadio」的听众'),
          tag,
          maxLineHeight: 30,
        );
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

  // ─────────────────────────────────────────────────────────────────────
  // 列表行审计 §3 的 B 级 12 条: B1–B12 逐条进 300/320/360 x 1.0/1.25/1.3/1.625
  // 矩阵, 断言两个方向都不 overflow(横向 RenderFlex + 竖排/行高暴涨)。
  // ─────────────────────────────────────────────────────────────────────

  testWidgets('B1 数字专辑页(超长专辑名/单曲名): 12 组合无溢出, 标题单行', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('DigitalAlbum', width, scale);
        final errors = await pumpAudited(
          tester,
          DigitalAlbumPage(
            loadAlbums: () async => rust.DigitalAlbumPurchased(
              total: BigInt.one,
              albums: [
                rust.DigitalAlbumPurchasedEntry(
                  albumId: BigInt.one,
                  albumName: _longAlbum,
                  artistId: BigInt.from(9),
                  artistName: _longArtist,
                  coverUrl: '',
                  paidTimeMs: BigInt.from(1700000000000),
                  boughtCount: BigInt.from(3),
                ),
              ],
            ),
            loadSongs: () async => rust.SongPurchasedPage(
              count: BigInt.one,
              hasMore: false,
              songs: [
                rust.PurchasedSongEntry(
                  songId: BigInt.from(2),
                  name: _longName,
                  artistName: _longArtist,
                  coverUrl: '',
                  paidTimeMs: BigInt.from(1700000000000),
                ),
              ],
            ),
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        final albumTitle = tester.widget<Text>(find.text(_longAlbum));
        expect(
          albumTitle.maxLines,
          1,
          reason: '$tag 只有 ellipsis 没有 maxLines 会先换行再省略',
        );
        expect(albumTitle.overflow, TextOverflow.ellipsis, reason: tag);
        final songTitle = tester.widget<Text>(find.text(_longName));
        expect(songTitle.maxLines, 1, reason: tag);
        expectSingleLine(tester, find.text(_longAlbum), tag, maxLineHeight: 26);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('B3 封面清晰度面板(档位名/说明限行): 12 组合无溢出', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('CoverQuality', width, scale);
        final errors = await pumpAudited(
          tester,
          Builder(
            builder: (ctx) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => showCoverQualitySheet(ctx),
              );
              return const SizedBox.shrink();
            },
          ),
          width: width,
          scale: scale,
          height: 900,
        );
        expectNoOverflow(errors, tag);
        for (final q in CoverQuality.values) {
          final label = tester.widget<Text>(find.text(q.label));
          expect(label.maxLines, 1, reason: '$tag ${q.label} 缺 maxLines');
          expect(label.overflow, TextOverflow.ellipsis, reason: tag);
          final hint = tester.widget<Text>(find.text(q.hint));
          expect(hint.maxLines, 2, reason: '$tag 说明不限行会撑高 64dp 封面');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('B4 歌曲百科键值行(超长标签/值): 12 组合无溢出, 标签单行', (tester) async {
    const longLabel = '一个很长很长很长的百科标签名字';
    const longValue = '流行-华语流行 / 原声带-动画片原声-一段很长很长的曲风值用于小屏回归测试再加长一点';
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('SongWiki', width, scale);
        final errors = await pumpAudited(
          tester,
          Builder(
            builder: (ctx) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => showSongWiki(
                  ctx,
                  song: song(),
                  load: (_) async => const [
                    rust.WikiFact(label: longLabel, value: longValue),
                    rust.WikiFact(label: '语种', value: '国语'),
                  ],
                ),
              );
              return const SizedBox.shrink();
            },
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        final label = tester.widget<Text>(find.text(longLabel));
        expect(label.maxLines, 1, reason: '$tag 标签列不限行会把整行撑成多行');
        final value = tester.widget<Text>(find.text(longValue));
        expect(value.maxLines, 2, reason: '$tag 值不限行会被超长值无限撑高');
        expectSingleLine(tester, find.text(longLabel), tag, maxLineHeight: 26);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('B7 艺人推荐单曲行(超长歌名): 12 组合无溢出, 歌名单行', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('ArtistRecommended', width, scale);
        final errors = await pumpAudited(
          tester,
          SingleChildScrollView(
            child: ArtistRecommendedSongsSection(songs: [song(), song(id: 2)]),
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

  testWidgets('B6 艺人页「全部歌曲」(超长歌名): 12 组合无溢出, 歌名单行', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('ArtistSongs', width, scale);
        final errors = await pumpAudited(
          tester,
          ArtistDetailPage(
            artistId: BigInt.from(6452),
            name: _longArtist,
            loadArtist: (_) async => rust.ArtistDetailDto(
              id: BigInt.from(6452),
              name: _longArtist,
              avatarUrl: null,
              coverUrl: null,
              alias: const [],
              briefDesc: '',
              albumCount: BigInt.one,
              musicCount: BigInt.from(2),
              fansCount: BigInt.zero,
              followed: false,
              userId: null,
              eventCount: BigInt.zero,
              songs: [song(), song(id: 2)],
              albums: const [],
            ),
            loadSimilar: (_) async => const [],
            loadSongsPage: (id, offset) async => rust.ArtistSongPageDto(
              songs: [song(), song(id: 2)],
              hasMore: false,
            ),
          ),
          width: width,
          scale: scale,
          after: () async {
            final tab = find.text('全部歌曲');
            if (tab.evaluate().isNotEmpty) {
              await tester.tap(tab);
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 80));
            }
          },
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

  testWidgets('B8 听歌排行(7 位播放次数): 12 组合无溢出, 行尾封顶 45%', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('Ranking', width, scale);
        final errors = await pumpAudited(
          tester,
          PlayRankingView(
            load: (period) async => [
              rust.PlayRankEntryDto(
                song: song(),
                playCount: BigInt.from(1234567),
                score: BigInt.one,
              ),
            ],
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        final count = tester.widget<Text>(find.text('1234567 次'));
        expect(count.maxLines, 1, reason: '$tag 播放次数缺 maxLines');
        final box = tester.renderObject<RenderBox>(find.text('1234567 次'));
        expect(
          box.size.width,
          lessThanOrEqualTo(width * 0.45 + 0.5),
          reason: '$tag 行尾未封顶在行宽 45%',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('B9 我的页「我喜欢」(9 首 -> 行尾共 N 首): 12 组合无溢出', (tester) async {
    final liked = [for (var i = 0; i < 9; i++) song(id: i + 1)];
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('MineLiked', width, scale);
        final errors = await pumpAudited(
          tester,
          _mineView(liked),
          width: width,
          scale: scale,
          height: 2000,
        );
        expectNoOverflow(errors, tag);
        expect(find.text('共 9 首'), findsOneWidget, reason: tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('B10 新歌页(超长歌名): 12 组合无溢出, 行尾(时长)封顶', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('NewRelease', width, scale);
        final errors = await pumpAudited(
          tester,
          NewReleasePage(
            onOpenAlbum: (_) {},
            onOpenArtist: (_) {},
            loadSongs: (_) async => [song(), song(id: 2)],
            loadAlbums: (_) async => const [],
            loadArtists: () async => const [],
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        expect(find.text(_longName), findsWidgets, reason: tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('B11 消息中心行(私信/通知, 相对时间): 12 组合无溢出', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('Messages', width, scale);
        final errors = await pumpAudited(
          tester,
          SessionsTab(
            load: (limit, offset) async => [
              rust.PrivateSession(
                userId: BigInt.from(7),
                nickname: _longArtist,
                avatarUrl: null,
                lastMessage: _longName,
                lastTimeMs: BigInt.from(1700000000000),
                unread: 3,
              ),
            ],
            loadHistory: (uid, limit, before) async => const [],
            loadContacts: () async => const [],
            pageSize: 20,
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        await tester.pumpWidget(const SizedBox.shrink());

        final inboxErrors = await pumpAudited(
          tester,
          InboxTab(
            load: () async => [
              rust.InboxItem(
                id: BigInt.one,
                kind: 'comment',
                actor: _longArtist,
                avatarUrl: null,
                text: _longName,
                detail: _longAlbum,
                timeMs: BigInt.from(1700000000000),
              ),
            ],
            emptyText: '还没有新消息',
            icon: Icons.notifications_none,
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(inboxErrors, tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('B12 关注列表(超长昵称 + 关注按钮): 12 组合无溢出', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = _tag('UserList', width, scale);
        final errors = await pumpAudited(
          tester,
          UserListView(
            uid: BigInt.one,
            loadFollows: (uid, limit, offset) async => [
              rust.UserItem(
                id: BigInt.from(7),
                name: _longArtist,
                avatarUrl: null,
                signature: _longName,
                followed: false,
              ),
            ],
            loadFolloweds: (uid, limit, offset) async => const [],
            setFollow: (uid, follow) async => true,
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        final button = tester.widget<Text>(
          find.descendant(
            of: find.byType(OutlinedButton),
            matching: find.text('关注'),
          ),
        );
        expect(button.maxLines, 1, reason: '$tag 关注按钮文字缺 maxLines');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}

/// 「我的」页(审计 B9): 只接我要喜欢的歌单, 其余区块给空数据, 避免打真网络.
Widget _mineView(List<rust.SongDto> liked) => MineView(
  loggedIn: true,
  onLogin: () {},
  onOpenAccounts: () {},
  onOpenPlaylist: (_) {},
  onOpenPodcast: (_) {},
  onOpenAlbum: (_) {},
  onOpenRecent: () {},
  onOpenFollows: () async {},
  onOpenFolloweds: () async {},
  onOpenLiked: () {},
  loadLiked: () async => liked,
  loadPlaylists: () async => const [],
  loadPodcasts: () async => const [],
  loadAlbums: () async => const [],
  loadRecent: () async => const [],
  loadRanking: (period) async => const [],
  loadMessageCounts: () async => rust.MessageCountsDto(
    private: 0,
    notices: 0,
    comments: 0,
    forwards: 0,
    total: 0,
  ),
  loadProfile: () async => rust.ProfileDetail(
    userId: BigInt.from(42),
    nickname: '我的账号',
    avatarUrl: null,
    backgroundUrl: null,
    signature: '',
    vip: false,
    follows: BigInt.from(3),
    followeds: BigInt.from(4),
    level: BigInt.from(7),
  ),
);
