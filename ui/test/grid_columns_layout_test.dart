import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/paged_list_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_results.dart';

/// 方格网格列数 / 窄视口布局回归(2026-11 用户反馈)。
///
/// 断言的是**几何**: 每一列的右边界都必须落在视口(或容器)内, 且每行正好
/// `AppSettings.gridColumns` 张卡片。用 [WidgetTester.getRect] 直接量, 不靠截图。

const _pagePadding = EdgeInsets.fromLTRB(kPagePadding, 12, kPagePadding, 24);

/// 把测试窗口设成 [width] × [height] 逻辑像素(devicePixelRatio = 1)。
void useScreen(WidgetTester tester, double width, {double height = 800}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

class _Item {
  const _Item(this.name);
  final String name;
}

/// 最小网格宿主: 与生产调用点一致的 PagedListView + coverGridDelegate。
Widget gridHost({required int columns, required double width}) {
  final items = [for (var i = 0; i < 12; i++) _Item('item$i')];
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: PagedListView<_Item>(
            loader: (_) async => PagedPage(items, hasMore: false),
            keyOf: (it) => it.name,
            padding: _pagePadding,
            gridDelegateBuilder: (context, availableWidth) => coverGridDelegate(
              availableWidth,
              columns: columns,
              crossAxisSpacing: 10,
              textScaler: MediaQuery.textScalerOf(context),
            ),
            itemBuilder: (context, item, i, all) => ColoredBox(
              key: ValueKey('cell-$i'),
              color: Colors.blueGrey,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 量出前 [columns] 个格子的矩形。
List<Rect> firstRowCells(WidgetTester tester, int columns) => [
  for (var i = 0; i < columns; i++)
    tester.getRect(find.byKey(ValueKey('cell-$i'))),
];

void main() {
  final settings = AppSettings.instance;
  tearDown(() {
    // 单例: 每条用例都恢复默认 3 列, 避免互相污染
    settings.gridColumns = 3;
  });

  testWidgets('3 列: 屏宽 360 + 页面 padding 12 时一行 3 格, 第三列右边界在视口内', (
    tester,
  ) async {
    useScreen(tester, 360);
    settings.gridColumns = 3;

    await tester.pumpWidget(
      gridHost(columns: settings.gridColumns, width: 360),
    );
    await tester.pumpAndSettle();

    final cells = firstRowCells(tester, 3);
    // 同一行
    expect(cells.map((r) => r.top.round()).toSet().length, 1);
    // 左贴 padding, 右贴 padding(均分铺满, 末端不留空隙)
    expect(cells.first.left, closeTo(kPagePadding, 0.01));
    expect(cells.last.right, closeTo(360 - kPagePadding, 0.5));
    // 三列都完整落在视口内 —— 用户反馈的「第三列被裁到屏幕外」在这里就会红
    for (final r in cells) {
      expect(r.right, lessThanOrEqualTo(360 - kPagePadding + 0.5));
      expect(r.width, greaterThan(20));
    }
    // 等宽
    for (final r in cells) {
      expect(r.width, closeTo(cells.first.width, 0.01));
    }
  });

  testWidgets('4 列: 同样均分铺满, 第四列右边界在视口内', (tester) async {
    useScreen(tester, 360);
    settings.gridColumns = 4;

    await tester.pumpWidget(
      gridHost(columns: settings.gridColumns, width: 360),
    );
    await tester.pumpAndSettle();

    final cells = firstRowCells(tester, 4);
    expect(cells.map((r) => r.top.round()).toSet().length, 1);
    expect(cells.first.left, closeTo(kPagePadding, 0.01));
    expect(cells.last.right, closeTo(360 - kPagePadding, 0.5));
    for (final r in cells) {
      expect(r.right, lessThanOrEqualTo(360 - kPagePadding + 0.5));
    }
    // 4 列格子比 3 列窄
    expect(cells.first.width, lessThan(360 / 4));
  });

  testWidgets('窄视口/窄容器(300dp 屏里的 220dp 容器): 格子宽按真实可用宽度算', (tester) async {
    useScreen(tester, 300);
    settings.gridColumns = 3;

    await tester.pumpWidget(
      gridHost(columns: settings.gridColumns, width: 220),
    );
    await tester.pumpAndSettle();

    final cells = firstRowCells(tester, 3);
    // 容器居中: 左 40, 右 260; 减 padding 后可用 196
    expect(cells.first.left, closeTo(40 + kPagePadding, 0.5));
    expect(cells.last.right, closeTo(260 - kPagePadding, 0.5));
    // 格子宽 = (196 - 2×10) / 3 = 58.67
    expect(cells.first.width, closeTo(coverTileWidth(196, 3), 0.5));
    for (final r in cells) {
      expect(r.right, lessThanOrEqualTo(260 - kPagePadding + 0.5));
    }
  });

  testWidgets('艺人网格每行列数 == AppSettings.gridColumns', (tester) async {
    useScreen(tester, 360);
    settings.gridColumns = 4;

    final artists = [
      for (var i = 0; i < 8; i++)
        rust.SearchArtist(
          id: BigInt.from(i),
          name: 'artist$i',
          alias: '',
          albumCount: BigInt.from(12),
          musicCount: BigInt.from(100),
        ),
    ];
    final bundle = rust.SearchBundleDto(
      songs: const [],
      songTotal: BigInt.zero,
      artists: artists,
      albums: const [],
      playlists: const [],
      podcasts: const [],
      users: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchResultsView(
            bundle: bundle,
            liked: const {},
            currentTrackId: null,
            onPlaySong: (_) {},
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
            onOpenPlaylist: (_) {},
            onOpenPodcast: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final rects = [
      for (var i = 0; i < 8; i++) tester.getRect(find.text('artist$i')),
    ];
    final firstTop = rects.first.top;
    // 第一行正好 4 张, 第 5 张换行
    for (var i = 0; i < 4; i++) {
      expect(rects[i].top, closeTo(firstTop, 0.01), reason: '第 $i 张应与首张同行');
    }
    expect(rects[4].top, greaterThan(firstTop), reason: '第 5 张应换到第二行');
    // 卡片右边界不越出页面 padding
    expect(
      rects[3].right,
      lessThanOrEqualTo(360 - kPagePadding + 0.5),
      reason: '第 4 张(最右列)不得溢出视口',
    );

    // 改成 2 列立即变 2 张/行(设置档位真的生效)
    settings.gridColumns = 2;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchResultsView(
            key: const ValueKey('rebuilt'),
            bundle: bundle,
            liked: const {},
            currentTrackId: null,
            onPlaySong: (_) {},
            onOpenArtist: (_) {},
            onOpenAlbum: (_) {},
            onOpenPlaylist: (_) {},
            onOpenPodcast: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final rects2 = [
      for (var i = 0; i < 8; i++) tester.getRect(find.text('artist$i')),
    ];
    expect(rects2[1].top, closeTo(rects2.first.top, 0.01));
    expect(rects2[2].top, greaterThan(rects2.first.top));
  });
}
