import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_results.dart';
import 'package:minincm/src/search_suggest.dart';

/// lane/search-grid 回归: 需求 8(网格列数统一) / 14(联想占满高度) / 10(MV 分类) / 15(边缘留白)。
///
/// 断言的是**几何**: 每行正好 N 个格子、左右边界落在 kPagePadding 上、
/// 末行左对齐、联想面板高度 == 可用高度。全部用 getRect/getSize 实测, 不看截图。

void useScreen(WidgetTester tester, double width, {double height = 900}) {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

final _settings = AppSettings.instance;

rust.SuggestItem suggest(String kind, String title) => rust.SuggestItem(
  kind: kind,
  id: BigInt.one,
  title: title,
  subtitle: 'sub',
  coverUrl: null,
);

/// 每个分区 6 条(足够铺满 2/3/4 列 + 第二行), 名字带分区前缀便于定位。
rust.SearchBundleDto bundleOf() {
  return rust.SearchBundleDto(
    songs: const [],
    songTotal: BigInt.zero,
    artists: [
      for (var i = 0; i < 6; i++)
        rust.SearchArtist(
          id: BigInt.from(i),
          name: 'artist$i',
          avatarUrl: null,
          alias: '',
          albumCount: BigInt.from(3),
          musicCount: BigInt.from(30),
        ),
    ],
    albums: [
      for (var i = 0; i < 6; i++)
        rust.SearchAlbum(
          id: BigInt.from(i),
          name: 'album$i',
          coverUrl: null,
          artist: '艺人',
          trackCount: BigInt.from(10),
        ),
    ],
    playlists: [
      for (var i = 0; i < 6; i++)
        rust.SearchPlaylistItem(
          id: BigInt.from(i),
          name: 'playlist$i',
          coverUrl: null,
          creatorName: '创建者',
          trackCount: BigInt.from(20),
          playCount: BigInt.from(100),
        ),
    ],
    podcasts: [
      for (var i = 0; i < 6; i++)
        rust.SearchPodcast(
          id: BigInt.from(i),
          name: 'podcast$i',
          coverUrl: null,
          djName: '主播',
          programCount: BigInt.from(7),
          playCount: BigInt.from(200),
        ),
    ],
    users: [
      for (var i = 0; i < 6; i++)
        rust.UserItem(
          id: BigInt.from(i),
          name: 'user$i',
          avatarUrl: null,
          signature: '签名',
          followed: false,
        ),
    ],
    mvs: const [],
  );
}

List<SearchMv> mvsOf() => [
  for (var i = 0; i < 6; i++)
    SearchMv(
      id: BigInt.from(i),
      name: 'mv$i',
      artistName: '艺人',
      playCount: BigInt.from(12345),
    ),
];

Widget resultsHost(
  rust.SearchBundleDto bundle, {
  List<SearchMv> mvs = const <SearchMv>[],
  void Function(SearchMv mv)? onOpenMv,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SearchResultsView(
        bundle: bundle,
        mvs: mvs,
        onOpenMv: onOpenMv,
        liked: const <BigInt>{},
        currentTrackId: null,
        onPlaySong: (_) {},
        onOpenArtist: (_) {},
        onOpenAlbum: (_) {},
        onOpenPlaylist: (_) {},
        onOpenPodcast: (_) {},
      ),
    ),
  );
}

/// 某分区前 [count] 张卡片的矩形(卡片本体 = 包着文字的 InkWell)。
List<Rect> cardRects(WidgetTester tester, List<String> names) => [
  for (final name in names)
    tester.getRect(
      find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first,
    ),
];

Future<void> openSection(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(ChoiceChip, label));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    // 单例: 每条用例后恢复默认 3 列, 避免互相污染
    _settings.gridColumns = 3;
  });

  // 6 个卡片型分区 × 列数档位 × 两种屏宽
  const sections = <String, String>{
    '艺人': 'artist',
    '专辑': 'album',
    '歌单': 'playlist',
    '播客': 'podcast',
    '用户': 'user',
    'MV': 'mv',
  };

  for (final cols in [2, 3, 4]) {
    for (final width in [400.0, 800.0]) {
      testWidgets('n=$cols, 屏宽 $width: 每个分区每行 $cols 个, 均分铺满且右侧无额外留白', (
        tester,
      ) async {
        useScreen(tester, width);
        _settings.gridColumns = cols;
        await tester.pumpWidget(resultsHost(bundleOf(), mvs: mvsOf()));
        await tester.pumpAndSettle();

        for (final entry in sections.entries) {
          await openSection(tester, entry.key);
          final names = [for (var i = 0; i < cols; i++) '${entry.value}$i'];
          final rects = cardRects(tester, names);

          // 第一行正好 cols 个
          expect(
            rects.map((r) => r.top.round()).toSet().length,
            1,
            reason: '${entry.key}: 前 $cols 张应在同一行',
          );
          // 左贴页面留白
          expect(
            rects.first.left,
            closeTo(kPagePadding, 0.5),
            reason: '${entry.key}: 首列应贴 kPagePadding',
          );
          // 右上角贴页面留白 —— 右侧不留固定空白(需求 8)
          expect(
            rects.last.right,
            closeTo(width - kPagePadding, 0.5),
            reason: '${entry.key}: 末列右边应贴 kPagePadding(无右侧留白)',
          );
          // 等宽 + 间距统一
          for (final r in rects) {
            expect(r.width, closeTo(rects.first.width, 0.01));
          }
          for (var i = 1; i < rects.length; i++) {
            expect(
              rects[i].left - rects[i - 1].right,
              closeTo(kGridCrossSpacing, 0.5),
            );
          }
          // 一屏内每行只有 cols 个: 下一个换行
          final next = tester.getRect(
            find
                .ancestor(
                  of: find.text('${entry.value}$cols'),
                  matching: find.byType(InkWell),
                )
                .first,
          );
          expect(
            next.top,
            greaterThan(rects.first.top),
            reason: '${entry.key}: 第 ${cols + 1} 张应换行',
          );
          expect(next.left, closeTo(kPagePadding, 0.5), reason: '末行左对齐');
        }
      });
    }
  }

  testWidgets('末行不满左对齐(5 条 + 3 列): 第二行首张仍贴 kPagePadding', (tester) async {
    useScreen(tester, 400);
    _settings.gridColumns = 3;
    await tester.pumpWidget(resultsHost(bundleOf(), mvs: mvsOf()));
    await tester.pumpAndSettle();
    await openSection(tester, '专辑');

    final second = tester.getRect(
      find
          .ancestor(of: find.text('album3'), matching: find.byType(InkWell))
          .first,
    );
    expect(second.left, closeTo(kPagePadding, 0.5));
  });

  testWidgets('列数设置实时生效: 3 → 4 立刻变每行 4 个', (tester) async {
    useScreen(tester, 400);
    _settings.gridColumns = 3;
    // 生产里根节点用 AnimatedBuilder 监听 AppSettings(见 main.dart), 这里同样包一层
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: _settings,
        builder: (context, _) => resultsHost(bundleOf(), mvs: mvsOf()),
      ),
    );
    await tester.pumpAndSettle();
    await openSection(tester, '专辑');

    var rects = cardRects(tester, ['album0', 'album1', 'album2']);
    expect(rects.map((r) => r.top.round()).toSet().length, 1);

    // 走 update(): 生产里设置页也是这条路(会 notifyListeners, 根节点重建)
    await _settings.update(gridColumns: 4);
    await tester.pumpAndSettle();
    rects = cardRects(tester, ['album0', 'album1', 'album2', 'album3']);
    expect(
      rects.map((r) => r.top.round()).toSet().length,
      1,
      reason: '4 列应在同一行',
    );
    expect(rects.last.right, closeTo(400 - kPagePadding, 0.5));
  });

  // ---------------- 需求 14: 联想面板占满剩余高度 ----------------

  testWidgets('联想面板占满可用高度并可滚动到最后一条', (tester) async {
    useScreen(tester, 400, height: 800);
    final items = [for (var i = 0; i < 40; i++) suggest('song', 'song$i')];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SuggestionPanel(items: items, onSelected: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 以前被 ConstrainedBox(maxHeight: 280) 截成小矩形; 现在等于整页可用高度
    // (Card 自己带 margin, 量它内部的滚动体才是面板真实高度)
    final panel = tester.getSize(find.byType(ListView));
    expect(panel.height, greaterThan(280.0));
    // 需求 3 之后分类 tab 占掉一条高度, 列表区 = 整页 - tab 条 - 卡片底 margin
    expect(panel.height, greaterThan(800 - 120.0));
    expect(panel.width, closeTo(400 - 2 * kPagePadding, 1.0));

    // 内部自滚动: 最后一条要能滚到
    expect(find.text('song39'), findsNothing);
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(find.text('song39'), findsOneWidget);
  });

  // ---------------- 需求 10: MV 分类 ----------------

  test('联想 kind=mv 有标签与图标', () {
    expect(suggestKindLabel('mv'), 'MV');
    expect(suggestIcon('mv'), Icons.play_circle_outline);
  });

  testWidgets('联想面板用分类 tab 展示 MV', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SuggestionPanel(
            items: [suggest('song', '晴天'), suggest('mv', '晴天 (MV)')],
            onSelected: (_) {},
          ),
        ),
      ),
    );
    // 分类 tab 里两类的 chip 都在, 但正文只渲染当前分类(默认单曲)
    expect(find.text('MV 1'), findsOneWidget);
    expect(find.text('单曲 1'), findsOneWidget);
    expect(find.text('晴天 (MV)'), findsNothing);
    await tester.tap(find.text('MV 1'));
    await tester.pumpAndSettle();
    expect(find.text('晴天 (MV)'), findsOneWidget);
  });

  testWidgets('结果页有 MV 分区, 点卡片回调给到具体 MV', (tester) async {
    useScreen(tester, 400);
    _settings.gridColumns = 3;
    SearchMv? opened;
    await tester.pumpWidget(
      resultsHost(bundleOf(), mvs: mvsOf(), onOpenMv: (mv) => opened = mv),
    );
    await tester.pumpAndSettle();

    // 分类条里一定有 MV(空分类也显示, 只是点进去给提示)
    expect(find.widgetWithText(ChoiceChip, 'MV'), findsOneWidget);
    await openSection(tester, 'MV');
    expect(find.text('mv0'), findsOneWidget);

    final rects = cardRects(tester, ['mv0', 'mv1', 'mv2']);
    expect(rects.map((r) => r.top.round()).toSet().length, 1);
    expect(rects.first.left, closeTo(kPagePadding, 0.5));
    expect(rects.last.right, closeTo(400 - kPagePadding, 0.5));

    await tester.tap(find.text('mv0'));
    expect(opened?.id, BigInt.zero);
    expect(opened?.name, 'mv0');
  });

  testWidgets('后端还没给 MV 数据时: 分区仍在, 点进去是明确的空提示', (tester) async {
    useScreen(tester, 400);
    await tester.pumpWidget(resultsHost(bundleOf()));
    await tester.pumpAndSettle();
    await openSection(tester, 'MV');
    expect(find.text('「MV」没有匹配结果'), findsOneWidget);
  });
}
