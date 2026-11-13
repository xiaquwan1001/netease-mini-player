import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_page.dart';
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

var pumpSeq = 0;

Future<void> pump(
  WidgetTester tester, {
  rust.ArtistDetailDto? detailData,
  Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist,
  Future<List<rust.Artist>> Function(BigInt)? loadSimilar,
  Future<rust.ArtistSongPageDto> Function(BigInt, int)? loadSongsPage,
  Future<rust.ArtistMvPageDto> Function(BigInt, int)? loadMvsPage,
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
        // 「全部歌曲」现在是初始 tab, 测试默认给空 loader, 避免误触真实 rust API
        loadSongsPage:
            loadSongsPage ??
            (_, _) async =>
                const rust.ArtistSongPageDto(songs: [], hasMore: false),
        loadMvsPage:
            loadMvsPage ??
            (_, _) async => const rust.ArtistMvPageDto(mvs: [], hasMore: false),
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
    find.text('全部歌曲'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('tab 数量: 无 MV 无专辑时只显示 热门歌曲/全部歌曲', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, albums: 0),
      loadSongsPage: (_, _) async =>
          const rust.ArtistSongPageDto(songs: [], hasMore: false),
    );
    // 「热门歌曲」tab 已移除, 改为顶部「推荐单曲」区块
    expect(find.text('推荐单曲'), findsOneWidget);
    // 横幅改成 220 高 + 身份卡, 初始视口内看不到 TabBar, 先滚进来
    await revealTabs(tester);
    expect(find.text('全部歌曲'), findsOneWidget);
    expect(find.text('专辑'), findsNothing);
    expect(find.text('MV'), findsNothing);
    expect(find.text('动态'), findsNothing);
  });

  testWidgets('tab 数量: 有 MV 时显示 MV tab, 探测失败时不显示', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2),
      loadMvsPage: (_, _) async =>
          rust.ArtistMvPageDto(mvs: [mv(0)], hasMore: false),
      loadSongsPage: (_, _) async =>
          const rust.ArtistSongPageDto(songs: [], hasMore: false),
    );
    await revealTabs(tester);
    expect(find.text('MV'), findsOneWidget);

    // 探测失败(抛异常) → 不显示 MV tab
    await pump(
      tester,
      detailData: detail(songs: 2),
      loadMvsPage: (_, _) async => throw Exception('mv 挂了'),
      loadSongsPage: (_, _) async =>
          const rust.ArtistSongPageDto(songs: [], hasMore: false),
    );
    expect(find.text('MV'), findsNothing);
  });

  testWidgets('切换 tab: 全部歌曲 tab 用自己的 loader 加载', (tester) async {
    var allSongsCalls = 0;
    await pump(
      tester,
      detailData: detail(songs: 2),
      loadSongsPage: (id, offset) async {
        allSongsCalls++;
        return rust.ArtistSongPageDto(
          songs: [song(90, name: '冷门')],
          hasMore: false,
        );
      },
    );
    expect(find.text('歌曲0'), findsOneWidget);
    await revealTabs(tester);
    await tester.tap(find.text('全部歌曲'));
    await tester.pumpAndSettle();
    expect(allSongsCalls, greaterThanOrEqualTo(1));
    expect(find.text('冷门90'), findsOneWidget);
  });

  testWidgets('切换 tab: MV tab 用自己的 loader 加载, 分页追加不重复', (tester) async {
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
    // 触底加载第二页
    await tester.scrollUntilVisible(
      find.text('MV999'),
      400,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.pumpAndSettle();
    // 触底只续下一页(offset 30), 不重拉第一页, 不重复
    expect(mvCalls, [0, 30]);
    expect(find.text('MV999'), findsOneWidget);
  });

  testWidgets('相似艺人胶囊横排(Wrap 水平方向), 300dp 大字号下不溢出', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, brief: '简介'),
      loadSimilar: (_) async => [
        rust.Artist(id: BigInt.from(1), name: '相似艺人甲', avatarUrl: null),
        rust.Artist(id: BigInt.from(2), name: '相似艺人乙', avatarUrl: null),
      ],
      textScaleBig: true,
    );
    expect(tester.takeException(), isNull);
    // 胶囊由水平方向的 Wrap 布局(横排, 放不下才换行)
    final wrap = find.ancestor(
      of: find.text('相似艺人甲'),
      matching: find.byType(Wrap),
    );
    expect(wrap, findsWidgets);
    for (final w in tester.widgetList<Wrap>(wrap)) {
      expect(w.direction, Axis.horizontal);
    }
    // 每个胶囊都不超出屏幕宽度(无溢出)
    final screenW =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    for (final name in ['相似艺人甲', '相似艺人乙']) {
      final rect = tester.getRect(find.text(name));
      expect(rect.right, lessThanOrEqualTo(screenW));
    }
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
    // 先滚回推荐单曲区块(此时在视口上方, 需向上滚): detail.songs 已被展示
    await tester.scrollUntilVisible(
      find.text('推荐单曲'),
      -100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('歌曲0'), findsOneWidget);
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
    // (推荐单曲区块此时在视口上方, sliver 懒构建不保留; 搜索只作用于全部歌曲 tab)
    // 搜不存在的 → 空态
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

  testWidgets('300dp + textScale 1.25: 头部信息区与相似艺人胶囊不溢出', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, brief: '一句话简介'),
      loadSimilar: (_) async => [
        rust.Artist(
          id: BigInt.from(1),
          name: '一个名字特别特别特别特别特别长的艺人',
          avatarUrl: null,
        ),
        rust.Artist(
          id: BigInt.from(2),
          name: '另一个名字同样特别特别特别特别长的艺人',
          avatarUrl: null,
        ),
      ],
      textScaleBig: true,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('相似艺人'), findsOneWidget);
    expect(find.textContaining('特别长'), findsWidgets);
  });

  testWidgets('信息区分区顺序: 简介 → 推荐单曲 → 相似艺人(与用户页同一口径)', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, brief: '一句话简介'),
      loadSimilar: (_) async => [
        rust.Artist(id: BigInt.from(1), name: '相似艺人甲', avatarUrl: null),
      ],
    );
    final brief = tester.getRect(find.text('简介')).top;
    final songs = tester.getRect(find.text('推荐单曲')).top;
    final similar = tester.getRect(find.text('相似艺人')).top;
    // 作品在前, 纯跳转入口(相似艺人)放最后: 两页共用同一顺序
    expect(brief, lessThan(songs));
    expect(songs, lessThan(similar));
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

  testWidgets('tab 生成规则: 专辑/MV 可用性决定 tab 集合', (tester) async {
    await pump(
      tester,
      detailData: detail(songs: 2, albums: 1),
      loadMvsPage: (_, _) async =>
          rust.ArtistMvPageDto(mvs: [mv(0)], hasMore: false),
    );
    await revealTabs(tester);
    // 全部歌曲 / 专辑 / MV
    expect(find.byType(Tab), findsNWidgets(3));
    expect(find.text('全部歌曲'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('MV'), findsOneWidget);

    // 专辑数为 0 + 无 MV: 只剩全部歌曲
    await pump(tester, detailData: detail(songs: 2, albums: 0));
    await revealTabs(tester);
    expect(find.byType(Tab), findsNWidgets(1));
    expect(find.text('专辑'), findsNothing);
    expect(find.text('MV'), findsNothing);
  });

  testWidgets('动态 tab: MV 探测晚到后 tab 增加, 当前 tab 与内容不重置', (tester) async {
    final mvsProbe = Completer<rust.ArtistMvPageDto>();
    await pump(
      tester,
      detailData: detail(songs: 2, albums: 1),
      loadSongsPage: (_, _) async =>
          rust.ArtistSongPageDto(songs: [song(7, name: '冷门')], hasMore: false),
      loadMvsPage: (_, _) => mvsProbe.future,
    );
    await revealTabs(tester);
    expect(find.byType(Tab), findsNWidgets(2)); // 全部歌曲 / 专辑
    await tester.tap(find.text('全部歌曲'));
    await tester.pumpAndSettle();
    expect(find.text('冷门7'), findsOneWidget);

    // MV 探测回来: tab 由 2 -> 3(旧 controller 必须帧末 dispose, 见 syncProfileTabs)
    mvsProbe.complete(rust.ArtistMvPageDto(mvs: [mv(0)], hasMore: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Tab), findsNWidgets(3));
    expect(find.text('MV'), findsOneWidget);
    // 当前 tab 仍是「全部歌曲」, 内容没被重建回别的 tab
    expect(find.text('冷门7'), findsOneWidget);
  });

  testWidgets('300dp + textScale 1.625: 头部统计 chip 不溢出', (tester) async {
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
    expect(find.textContaining('个专辑'), findsOneWidget);
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
    // 触底前: 只有第一页
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
