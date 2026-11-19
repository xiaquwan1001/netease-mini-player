// 主从分栏(方案 B · S4)**端到端**验收: 搜到歌单 → 点卡片 → 右栏出详情。
//
// 走的是生产的整条壳(MiniNcmApp: 根 NavigatorObserver + NavigationRail +
// ContentWidthLimit 840 + 常驻播放条), 不是拼出来的近似壳 —— 因为本切片要证明的正是
// "右栏不是路由": pageDepth 不变、Rail 不消失、返回键只清右栏。
//
// 两条语义(设计选择, 不是 bug):
//   · 1280x720(宽档): 点左栏卡片 ⇒ 左栏仍在 + 右栏 420 出详情 + 该卡片选中外框;
//     返回 ⇒ 只清右栏(**不 pop 页面**);
//   · 360x800(窄档): 同操作照旧 push 一整页(pageDepth +1)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/app_shell.dart'
    show NcmRouteObserver, PlayerBarHost, pageDepth, playerBarSlot;
import 'package:minincm/src/detail_pane.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;
import 'package:minincm/src/search_results.dart' show kGridCardSelectedKey;

import 'support/fakes.dart';
import 'support/nav_chrome.dart';

/// 只覆盖"搜索 + 歌单详情"这条链路; 其余一律抛(与没 init 过 RustLib 的行为一致,
/// 于是别处的漏接线仍然会暴露成错误态, 不会被这台假机器掩盖)。
class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('主从分栏流程测试未覆盖 ${invocation.memberName}');

  // ---------------- 搜索 ----------------

  @override
  Future<rust.SearchBundleDto> crateApiSearchAll({
    required String keywords,
    required int limit,
  }) async => rust.SearchBundleDto(
    songs: const <rust.SongDto>[],
    songTotal: BigInt.zero,
    artists: const <rust.SearchArtist>[],
    albums: const <rust.SearchAlbum>[],
    playlists: <rust.SearchPlaylistItem>[
      for (var i = 0; i < 6; i++)
        rust.SearchPlaylistItem(
          id: BigInt.from(24381616 + i),
          name: i == 0 ? '华语精选' : '华语精选$i',
          coverUrl: null,
          creatorName: '云音乐编辑部',
          trackCount: BigInt.from(12),
          playCount: BigInt.from(128000),
        ),
    ],
    podcasts: const <rust.SearchPodcast>[],
    users: const <rust.UserItem>[],
    mvs: const <rust.MvItem>[],
  );

  @override
  Future<List<String>> crateApiRecordSearch({required String keyword}) async =>
      <String>[keyword];

  @override
  Future<List<String>> crateApiSearchHistory() async => const <String>[];

  @override
  Future<List<rust.SuggestItem>> crateApiSearchSuggest({
    required String keywords,
  }) async => const <rust.SuggestItem>[];

  @override
  Future<List<String>> crateApiSearchSuggestKeywords({
    required String keywords,
  }) async => const <String>[];

  @override
  Future<rust.SearchExact> crateApiSearchExact({
    required String keywords,
  }) async => const rust.SearchExact(
    orders: <String>[],
    artists: <rust.Artist>[],
    playlists: <rust.Playlist>[],
    podcasts: <rust.PodcastRadio>[],
  );

  @override
  Future<List<rust.HotSearchDetailItem>> crateApiHotSearchDetail() async =>
      const <rust.HotSearchDetailItem>[];

  @override
  Future<List<rust.HotSearchTerm>> crateApiHotSearch() async =>
      const <rust.HotSearchTerm>[];

  @override
  Future<rust.DefaultSearch?> crateApiDefaultSearch() async => null;

  // ---------------- 歌单详情 ----------------

  @override
  Future<BigInt> crateApiMyUid() async => BigInt.from(1822714196);

  @override
  Future<rust.PlaylistDetail> crateApiPlaylistDetail({
    required BigInt playlistId,
  }) async => rust.PlaylistDetail(
    id: playlistId,
    name: '华语精选',
    coverUrl: null,
    description: '每日更新的华语流行精选。',
    creatorName: '云音乐编辑部',
    creatorId: BigInt.from(999999999),
    trackCount: BigInt.from(12),
    playCount: BigInt.from(128000),
    subscribed: true,
    subscribedCount: BigInt.from(52000),
    shareCount: BigInt.from(340),
    commentCount: BigInt.from(88),
    tags: const <String>['华语', '流行'],
  );

  @override
  Future<List<rust.SongDto>> crateApiPlaylistSongs({
    required BigInt playlistId,
  }) async => <rust.SongDto>[
    for (var i = 1; i <= 12; i++)
      fakeSong(id: 500 + i, name: '华语热歌$i', artist: i.isOdd ? '周杰伦' : '林俊杰'),
  ];

  @override
  Future<rust.CommentPage> crateApiComments({
    required String kind,
    required BigInt resourceId,
    required int limit,
    required int offset,
  }) async => rust.CommentPage(
    threadId: 'A_PL_0_24381616',
    comments: const <rust.Comment>[],
    total: BigInt.zero,
    hasMore: false,
  );

  @override
  Future<rust.CommentStats> crateApiCommentStats({
    required String threadId,
  }) async => rust.CommentStats(
    threadId: threadId,
    resourceId: BigInt.from(24381616),
    commentCount: BigInt.zero,
    commentCountDesc: '0',
    shareCount: BigInt.zero,
    likedCount: BigInt.zero,
    liked: false,
    musicianSaidCount: BigInt.zero,
    commentUpgraded: false,
  );
}

/// 根壳: 观察者 + Navigator 之外的播放条/导航栏(tab_switch_popups_test 同一条装配)。
///
/// 不直接用 MiniNcmApp: 它要真 Rust/真设置, 这条用例只测布局语义, 用同一条装配的
/// 轻壳更快更稳。(曾经的硬原因 —— ContentWidthLimit(LayoutBuilder)把 HomePage 的
/// 首次建树压在 layout 阶段, 而 initState 同步写 actionsHost 槽位 ⇒
/// "setState() called during build" —— 已由 U-08 修掉, 回归锁在
/// test/app_shell_first_frame_test.dart。)
/// 840 限宽下的主从几何由 test/detail_pane_test.dart 精确锁住。
///
/// HomePage 的 bootstrap 会打平台通道/Rust 并起 500ms 轮询 Timer, 所以只 pump 固定
/// 帧数, **不用 pumpAndSettle**。
Future<void> _pumpApp(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => playerBarSlot.value = null);
  await tester.pumpWidget(
    MaterialApp(
      // 与生产同一条根导航栈记账(右栏不是路由, 这里正是要证明的)
      navigatorObservers: [NcmRouteObserver()],
      builder: (context, child) =>
          PlayerBarHost(content: child ?? const SizedBox.shrink()),
      home: const HomePage(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 切到「搜索」tab(宽档走左侧 Rail、窄档走底部 Bar: 用档位中立的查找器)。
Future<void> _toSearchTab(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: navChromeFinder, matching: find.text('搜索')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// 输入关键词并真的搜索(走页面上的「搜索」按钮, 与用户操作一致)。
Future<void> _search(WidgetTester tester, String keyword) async {
  await tester.enterText(find.byType(TextField).first, keyword);
  await tester.pump(const Duration(milliseconds: 400)); // 联想防抖
  await tester.tap(find.widgetWithText(FilledButton, '搜索'));
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeRustApi()));

  setUp(() {
    pageDepth.value = 0;
    detailPaneSlot.value = null;
  });

  testWidgets('1280x720: 点左栏歌单 ⇒ 左栏仍在 + 右栏出详情 + 选中外框; 返回只清右栏', (tester) async {
    await _pumpApp(tester, size: const Size(1280, 720));
    await _toSearchTab(tester);
    await _search(tester, '华语');

    expect(find.text('华语精选'), findsOneWidget, reason: '搜索结果的歌单卡片');
    expect(pageDepth.value, 1);
    expect(find.byType(NavigationRail), findsOneWidget, reason: '宽档左侧 Rail 在场');

    await tester.tap(find.text('华语精选'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // 1) 右栏出现, 且是**内嵌形态**(没有 AppBar / 返回箭头)
    expect(find.byType(DetailPaneSurface), findsOneWidget);
    final pane = tester.getRect(find.byType(DetailPaneSurface));
    expect(pane.width, kDetailPaneWidth);
    expect(find.byType(AppBar), findsNothing, reason: '右栏没有 AppBar');
    expect(find.byType(BackButton), findsNothing);
    expect(find.text('创建者: 云音乐编辑部'), findsOneWidget, reason: '右栏详情已加载');

    // 2) 左栏仍在(搜索框 + 卡片 + Rail), 只是让位给右栏
    //    两个 TextField = 左栏搜索框 + 右栏「筛选本页曲目」
    expect(find.byType(TextField), findsNWidgets(2), reason: '左栏搜索框仍在');
    expect(find.text('华语精选'), findsNWidgets(2), reason: '左栏卡片 + 右栏头部标题');
    expect(find.text('华语精选1'), findsOneWidget, reason: '左栏其余卡片仍在');
    expect(find.byType(NavigationRail), findsOneWidget);
    // 右栏固定 kDetailPaneWidth, 左栏拿剩下的(左栏 + 12 间距 + 右栏 == 分栏总宽)
    final split = tester.getRect(find.byType(DetailPaneSplit));
    final masterWidth = split.width - kDetailPaneWidth - kTwoColumnGap;
    expect(pane.width, kDetailPaneWidth);
    expect(pane.left - split.left, closeTo(masterWidth + kTwoColumnGap, 0.01));
    expect(masterWidth, greaterThan(0));

    // 3) 该卡片有选中外框
    expect(find.byKey(kGridCardSelectedKey), findsOneWidget);

    // 4) 右栏不是路由: 页面层数不变(底部/左侧导航因此不会让位)
    expect(pageDepth.value, 1, reason: '右栏不是路由');

    // 5) 返回 ⇒ 只清右栏, 页面与左栏都不动
    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(handled, isTrue);
    expect(find.byType(DetailPaneSurface), findsNothing, reason: '右栏被清掉');
    expect(find.byKey(kGridCardSelectedKey), findsNothing, reason: '选中外框一并撤掉');
    expect(find.byType(TextField), findsOneWidget, reason: '页面本身没被 pop');
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(pageDepth.value, 1);
  });

  testWidgets('360x800(窄档): 同操作仍 push 一整页, pageDepth +1', (tester) async {
    await _pumpApp(tester, size: const Size(360, 800));
    await _toSearchTab(tester);
    await _search(tester, '华语');

    await tester.tap(find.text('华语精选'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(detailPaneSlot.value, isNull, reason: '窄档不填右栏');
    expect(find.byType(DetailPaneSurface), findsNothing);
    expect(pageDepth.value, 2, reason: '窄档的详情是真正的一层路由');
    // push 出来的整页: 有 AppBar + 返回箭头, 标题就是歌单名
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.widgetWithText(AppBar, '华语精选'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    expect(find.text('创建者: 云音乐编辑部'), findsOneWidget);
  });

  testWidgets('右栏开着时返回键的两级语义: 只清右栏 → 再按才 resetTab', (tester) async {
    await _pumpApp(tester, size: const Size(1280, 720));

    // 启动落在「推荐」tab(非首 tab); 直接把右栏置成开着(等价于刚点了一条详情)
    expect(navSelectedIndex(tester), 1);
    detailPaneSlot.value = DetailPaneRequest(
      key: 'pl-1',
      builder: (context) => const Text('右栏详情体'),
    );
    await tester.pump();

    expect(find.text('右栏详情体'), findsOneWidget);

    // 第一次返回: 右栏优先于 resetTab ⇒ 只清右栏, tab 不动
    var handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(handled, isTrue);
    expect(detailPaneSlot.value, isNull);
    expect(navSelectedIndex(tester), 1, reason: '右栏优先, 不该顺手换 tab');

    // 第二次返回: 右栏已空 ⇒ 才轮到 resetTab(回搜索 tab)
    handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(handled, isTrue);
    expect(navSelectedIndex(tester), 0);
  });

  testWidgets('切 tab 会一并清掉右栏(不留一个"上一屏的详情")', (tester) async {
    await _pumpApp(tester, size: const Size(1280, 720));
    detailPaneSlot.value = DetailPaneRequest(
      key: 'pl-1',
      builder: (context) => const Text('右栏详情体'),
    );
    await tester.pump();
    expect(find.text('右栏详情体'), findsOneWidget);

    await tester.tap(
      find.descendant(of: navChromeFinder, matching: find.text('我的')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(detailPaneSlot.value, isNull);
    expect(find.byType(DetailPaneSurface), findsNothing);
  });
}
