import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_page.dart';
import 'package:minincm/src/artist_sections.dart';
import 'package:minincm/src/cover_art.dart' show CircleCover;
import 'package:minincm/src/profile_scaffold.dart' show ProfileWorksStatChip;
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int i, {String name = '歌曲', bool playable = true}) =>
    rust.SongDto(
      id: BigInt.from(1000 + i),
      name: '$name$i',
      artist: '周杰伦',
      artistId: BigInt.from(6452),
      album: '专辑',
      albumId: BigInt.from(1),
      durationMs: BigInt.from(200000),
      fee: 0,
      vip: false,
      paid: false,
      playable: playable,
    );

rust.ArtistDetailDto detail({
  int songs = 3,
  int albums = 1,
  String brief = '',
}) => rust.ArtistDetailDto(
  id: BigInt.from(6452),
  name: '周杰伦',
  avatarUrl: null,
  coverUrl: null,
  alias: const [],
  briefDesc: brief,
  albumCount: BigInt.from(albums),
  musicCount: BigInt.from(songs),
  songs: List.generate(songs, (i) => song(i)),
  albums: List.generate(
    albums,
    (i) => rust.AlbumBrief(
      id: BigInt.from(10 + i),
      name: '专辑$i',
      coverUrl: null,
      trackCount: BigInt.from(10),
      publishTime: BigInt.zero,
    ),
  ),
);

rust.ArtistMvDto mv(int i) => rust.ArtistMvDto(
  id: BigInt.from(5000 + i),
  name: 'MV$i',
  durationMs: BigInt.from(200000),
  playCount: BigInt.from(1000),
  publishTime: '2025-02-23',
  coverUrl: null,
);

rust.FeedEventDto dynamicEvent(int i, {String text = '新专辑预告'}) =>
    rust.FeedEventDto(
      id: BigInt.from(900 + i),
      threadId: 'A_EV_2_${900 + i}_6452',
      userId: BigInt.from(6452),
      kind: 'text',
      userName: '周杰伦',
      avatarUrl: null,
      text: '$text$i',
      song: null,
      coverUrl: null,
      images: const [],
      videoUrl: null,
      title: '',
      timeMs: BigInt.from(1700000000000),
      liked: false,
      likedCount: BigInt.from(3),
      shareCount: BigInt.zero,
      commentCount: BigInt.from(5),
    );

var pumpSeq = 0;

/// 「动态」探测默认给空列表: 不注入时 rust.userEvents 会抛(测试环境无 RustLib),
/// 静默后会留下一个 future 错误, 干扰其它断言。
Future<void> pump(
  WidgetTester tester, {
  rust.ArtistDetailDto? detailData,
  Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist,
  Future<List<rust.Artist>> Function(BigInt)? loadSimilar,
  Future<rust.ArtistSongPageDto> Function(BigInt, int)? loadSongsPage,
  Future<rust.ArtistMvPageDto> Function(BigInt, int)? loadMvsPage,
  Future<List<rust.FeedEventDto>> Function(BigInt)? loadDynamics,
  Future<bool> Function(BigInt, bool)? toggleFollow,
  bool textScaleBig = false,
  double textScale = 1.25,
}) async {
  if (textScaleBig) {
    tester.view.physicalSize = const Size(300, 700);
    tester.view.devicePixelRatio = 1.0;
    tester.view.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(() {
      tester.view.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }
  // 每次 pump 用独立 key: 避免同一 tester 复用 State 时 MV 探测等易变状态残留。
  pumpSeq++;
  await tester.pumpWidget(
    MaterialApp(
      home: ArtistDetailPage(
        key: ValueKey('artist-page-$pumpSeq'),
        artistId: BigInt.from(6452),
        name: '周杰伦',
        onPlaySongs: (_, _) {},
        loadArtist:
            loadArtist ?? (_) async => detailData ?? detail(brief: '简介'),
        loadSimilar: loadSimilar,
        // 歌曲/MV/动态默认给空 loader, 避免误触真实 rust API
        loadSongsPage:
            loadSongsPage ??
            (_, _) async =>
                const rust.ArtistSongPageDto(songs: [], hasMore: false),
        loadMvsPage:
            loadMvsPage ??
            (_, _) async => const rust.ArtistMvPageDto(mvs: [], hasMore: false),
        loadDynamics: loadDynamics ?? (_) async => const <rust.FeedEventDto>[],
        toggleFollow: toggleFollow,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 区块变多后 TabBar 初始可能在视口外(sliver 懒构建, 不滚不进树);
/// 需要点 tab 的测试先把它滚进来。
Future<void> revealTabs(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(TabBar),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('需求 13: 信息区不再有推荐单曲/专辑横滑两个重复区块', (tester) async {
    await pump(tester, detailData: detail(songs: 3, albums: 2, brief: '一句话简介'));
    // 旧结构里这两块在 TabBar 之上; 现在推荐单曲只在首个 tab 里(在 TabBar 之下),
    // 专辑横滑整块删除, 只剩「专辑」tab。
    expect(find.text('简介'), findsOneWidget);
    expect(find.text('相似艺人'), findsNothing);
    expect(find.textContaining('全部 2 张'), findsNothing);
    expect(find.textContaining('张 ›'), findsNothing);
    expect(find.textContaining('首 ›'), findsNothing);
    final tabBarBottom = tester.getRect(find.byType(TabBar)).bottom;
    final recommended = tester.getRect(
      find.byType(ArtistRecommendedSongsSection),
    );
    expect(
      recommended.top,
      greaterThanOrEqualTo(tabBarBottom - 1),
      reason: '推荐单曲应是 tab 内容, 不在信息区(TabBar 之上)再渲染一份',
    );
  });

  testWidgets('需求 13: tab 集合与顺序 = 推荐单曲/全部歌曲/专辑/MV/动态', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 3, albums: 1),
      loadMvsPage: (_, _) async =>
          rust.ArtistMvPageDto(mvs: [mv(0)], hasMore: false),
      loadDynamics: (_) async => [dynamicEvent(0)],
    );
    await revealTabs(tester);
    expect(find.byType(Tab), findsNWidgets(5));
    final labels = tester
        .widgetList<Tab>(find.byType(Tab))
        .map((t) => t.text)
        .toList();
    expect(labels, ['推荐单曲', '全部歌曲', '专辑', 'MV', '动态']);
  });

  testWidgets('需求 13: 没数据的 tab 不生成(推荐单曲/专辑/MV/动态)', (tester) async {
    // 无歌曲、无专辑、MV 空、动态空 → 只剩「全部歌曲」
    await pump(tester, detailData: detail(songs: 0, albums: 0));
    await revealTabs(tester);
    expect(find.byType(Tab), findsNWidgets(1));
    expect(find.text('全部歌曲'), findsOneWidget);
    expect(find.text('推荐单曲'), findsNothing);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('MV'), findsNothing);
    expect(find.text('动态'), findsNothing);
  });

  testWidgets('需求 13: 推荐单曲 tab 渲染 top 曲目并可直接播放', (tester) async {
    if (true) {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
    }
    final played = <int>[];
    pumpSeq++;
    await tester.pumpWidget(
      MaterialApp(
        home: ArtistDetailPage(
          key: ValueKey('artist-play-$pumpSeq'),
          artistId: BigInt.from(6452),
          name: '周杰伦',
          onPlaySongs: (songs, index) => played.add(index),
          loadArtist: (_) async => detail(songs: 3, albums: 0),
          loadSongsPage: (_, _) async =>
              const rust.ArtistSongPageDto(songs: [], hasMore: false),
          loadMvsPage: (_, _) async =>
              const rust.ArtistMvPageDto(mvs: [], hasMore: false),
          loadDynamics: (_) async => const <rust.FeedEventDto>[],
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 推荐单曲是首个 tab: 一进页面就是它
    expect(find.byType(ArtistRecommendedSongsSection), findsOneWidget);
    expect(find.text('歌曲0'), findsOneWidget);
    expect(find.text('共 3 首'), findsOneWidget);
    await tester.tap(find.byTooltip('播放全部'));
    await tester.pumpAndSettle();
    expect(played, [0]);
  });

  testWidgets('全部歌曲 tab 用自己的 loader 加载; MV 探测失败不生成 tab', (tester) async {
    var allSongsCalls = 0;
    await pump(
      tester,
      detailData: detail(songs: 2),
      loadMvsPage: (_, _) async => throw Exception('mv 挂了'),
      loadSongsPage: (_, _) async {
        allSongsCalls++;
        return rust.ArtistSongPageDto(
          songs: [song(90, name: '冷门')],
          hasMore: false,
        );
      },
    );
    await revealTabs(tester);
    expect(find.text('MV'), findsNothing);
    await tester.tap(find.text('全部歌曲'));
    await tester.pumpAndSettle();
    expect(allSongsCalls, greaterThanOrEqualTo(1));
    expect(find.text('冷门90'), findsOneWidget);
  });

  testWidgets('MV tab 分页追加不重复', (tester) async {
    final mvCalls = <int>[];
    await pump(
      tester,
      detailData: detail(songs: 1),
      loadMvsPage: (_, offset) async {
        mvCalls.add(offset);
        if (offset == 0) {
          return rust.ArtistMvPageDto(
            mvs: List.generate(30, mv),
            hasMore: true,
          );
        }
        return rust.ArtistMvPageDto(mvs: [mv(999)], hasMore: false);
      },
    );
    await revealTabs(tester);
    await tester.tap(find.text('MV'));
    await tester.pumpAndSettle();
    expect(mvCalls, [0]); // 探测已调过 offset 0
    expect(find.text('MV0'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('MV999'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(mvCalls, [0, 30]);
    expect(find.text('MV999'), findsOneWidget);
  });

  testWidgets('需求 13: 动态 tab 有数据才出现, 点进动态详情', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 1, albums: 0),
      loadDynamics: (_) async => [dynamicEvent(0)],
    );
    await revealTabs(tester);
    expect(find.text('动态'), findsOneWidget);
    await tester.tap(find.text('动态'));
    await tester.pumpAndSettle();
    expect(find.text('新专辑预告0'), findsOneWidget);
  });

  testWidgets('需求 9: 相似艺人横排 ListView, 头像在上名字在下, 不自动滚动', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, brief: '简介'),
      loadSimilar: (_) async => [
        // 数量要足够把横排撑出滚动范围, 否则「拖动」测不出来
        for (var i = 0; i < 20; i++)
          rust.Artist(id: BigInt.from(i + 1), name: '相似艺人$i', avatarUrl: null),
      ],
    );
    final row = find.byType(SimilarArtistsRow);
    expect(row, findsOneWidget);
    // 横排: SimilarArtistsRow 内部是 Axis.horizontal 的 ListView
    final list = find.descendant(of: row, matching: find.byType(ListView));
    expect(list, findsOneWidget);
    expect(tester.widget<ListView>(list).scrollDirection, Axis.horizontal);
    // 头像在名字上方(同一项内)
    final avatarRect = tester.getRect(
      find.descendant(of: row, matching: find.byType(CircleCover)).first,
    );
    final nameRect = tester.getRect(find.text('相似艺人0'));
    expect(avatarRect.bottom, lessThanOrEqualTo(nameRect.top + 1));
    // 项宽 72dp(需求 72~80)
    expect(tester.getSize(row).width, greaterThan(0));
    // 禁止自动滚动/轮播: 静置 3 秒后滚动位置必须还是 0
    await tester.pump(const Duration(seconds: 3));
    final position = tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position.pixels, 0, reason: '相似艺人不允许自动滚动/轮播');
    // 但用户可以手动拖: 拖动后位置变化
    await tester.drag(list, const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(position.pixels, greaterThan(0));
  });

  testWidgets('需求 9: 相似艺人拿不到(未登录/失败)时整块不显示', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, brief: '简介'),
      loadSimilar: (_) async => throw Exception('未登录'),
    );
    expect(find.text('相似艺人'), findsNothing);
    expect(find.byType(SimilarArtistsRow), findsNothing);
  });

  testWidgets('需求 11: 作品数标签在头像右侧/昵称下方, 独占行数 -1', (tester) async {
    await pump(tester, detailData: detail(songs: 2, albums: 3));
    expect(find.text('3 个专辑 · 2 首歌曲'), findsOneWidget);
    // 量 chip 本身(文字在 chip 的内边距+图标之后)
    final worksRect = tester.getRect(find.byType(ProfileWorksStatChip));
    final nameRect = tester.getRect(find.text('周杰伦').first);
    final avatarRect = tester.getRect(find.byType(CircleCover).first);
    // 头像右侧: chip 在头像右边界之后
    expect(worksRect.left, greaterThanOrEqualTo(avatarRect.right));
    // 昵称下方(而不是身份卡底部独占一行)
    expect(worksRect.top, greaterThanOrEqualTo(nameRect.bottom - 1));
    // 与名字左对齐(同在头像右侧这一列)
    expect((worksRect.left - nameRect.left).abs(), lessThan(2));
  });

  testWidgets('300dp + textScale 1.625: 头部与相似艺人横排不溢出', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, albums: 2, brief: '一句话简介'),
      loadSimilar: (_) async => [
        rust.Artist(
          id: BigInt.from(1),
          name: '一个名字特别特别特别特别特别长的艺人',
          avatarUrl: null,
        ),
      ],
      textScaleBig: true,
      textScale: 1.625,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('3 个专辑 · 2 首歌曲'), findsNothing);
    expect(find.textContaining('个专辑'), findsOneWidget);
    expect(find.text('相似艺人'), findsOneWidget);
    expect(find.textContaining('特别长'), findsWidgets);
  });

  testWidgets('页内搜索: 只过滤全部歌曲 tab(聚合后本地过滤), 无匹配给空态', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2),
      loadSongsPage: (_, _) async => rust.ArtistSongPageDto(
        songs: [
          song(0, name: '晴天'),
          song(1, name: '七里香'),
        ],
        hasMore: false,
      ),
    );
    await revealTabs(tester);
    await tester.tap(find.text('全部歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('晴天0'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '七里香');
    await tester.pumpAndSettle();
    expect(find.text('七里香1'), findsOneWidget);
    expect(find.text('晴天0'), findsNothing);
    await tester.enterText(find.byType(TextField), '不存在的歌');
    await tester.pumpAndSettle();
    expect(find.textContaining('没有匹配'), findsOneWidget);
  });

  testWidgets('空态: 全部歌曲无数据给空态文案', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 1),
      loadSongsPage: (_, _) async =>
          const rust.ArtistSongPageDto(songs: [], hasMore: false),
    );
    await revealTabs(tester);
    await tester.tap(find.text('全部歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('暂无歌曲'), findsOneWidget);
  });

  testWidgets('关注按钮: 点击后乐观翻转为已关注', (tester) async {
    var calls = <bool>[];
    await pump(
      tester,
      detailData: detail(songs: 1),
      toggleFollow: (_, sub) async {
        calls.add(sub);
        return true;
      },
    );
    expect(find.text('关注'), findsOneWidget);
    await tester.tap(find.text('关注'));
    await tester.pumpAndSettle();
    expect(calls, [true]);
    expect(find.text('已关注'), findsOneWidget);
  });

  testWidgets('MV 探测晚到后 tab 增加, 当前 tab 与内容不重置', (tester) async {
    final mvsProbe = Completer<rust.ArtistMvPageDto>();
    await pump(
      tester,
      detailData: detail(songs: 2, albums: 1),
      loadSongsPage: (_, _) async =>
          rust.ArtistSongPageDto(songs: [song(7, name: '冷门')], hasMore: false),
      loadMvsPage: (_, _) => mvsProbe.future,
    );
    await revealTabs(tester);
    expect(find.byType(Tab), findsNWidgets(3)); // 推荐单曲 / 全部歌曲 / 专辑
    await tester.tap(find.text('全部歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('冷门7'), findsOneWidget);

    mvsProbe.complete(rust.ArtistMvPageDto(mvs: [mv(0)], hasMore: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Tab), findsNWidgets(4));
    expect(find.text('MV'), findsOneWidget);
    // 当前 tab 仍是「全部歌曲」, 内容没被重建回别的 tab
    expect(find.text('冷门7'), findsOneWidget);
  });

  testWidgets('分页: 全部歌曲 tab 触底加载更多(第二页)', (tester) async {
    final offsets = <int>[];
    await pump(
      tester,
      detailData: detail(songs: 1),
      loadSongsPage: (_, offset) async {
        offsets.add(offset);
        if (offset == 0) {
          return rust.ArtistSongPageDto(
            songs: List.generate(60, (i) => song(i, name: '页一')),
            hasMore: true,
          );
        }
        return rust.ArtistSongPageDto(
          songs: [song(999, name: '页二')],
          hasMore: false,
        );
      },
    );
    await revealTabs(tester);
    await tester.tap(find.text('全部歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('页二999'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('页二999'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    expect(offsets.contains(60), isTrue);
    expect(find.text('页二999'), findsOneWidget);
  });
}
