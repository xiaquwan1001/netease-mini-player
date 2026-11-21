// 歌单详情页的「常驻搜索」入口(2026-11-22 用户反馈第 2 条)。
//
// 口径见 lib/src/detail/playlist_detail_page.dart 的 _buildActions / _focusFilter:
//   · AppBar(内嵌形态是顶部动作行)第一个动作是 Icons.search(tooltip「搜索本页」);
//   · 曲目列表滚到中部后按钮仍在 AppBar 里;
//   · 点它把筛选条滚进视野并让筛选框拿到焦点(不必手动滑回顶部)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail/playlist_detail_page.dart';
import 'package:minincm/src/layout.dart' show ContentWidthLimit;
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;

import 'support/fakes.dart';

/// 歌单详情页只有命令式入口且数据直连 FFI, 这里垫最小一套(5 个方法)。
class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('歌单详情搜索入口测试未覆盖 ${invocation.memberName}');

  @override
  Future<BigInt> crateApiSocialMyUid() async => BigInt.from(1822714196);

  @override
  Future<rust.PlaylistDetail> crateApiDetailPlaylistDetail({
    required BigInt playlistId,
  }) async => rust.PlaylistDetail(
    id: BigInt.from(24381616),
    name: '华语流行精选',
    coverUrl: null,
    description: '每日更新的华语流行精选。',
    creatorName: '云音乐编辑部',
    creatorId: BigInt.from(999999999),
    trackCount: BigInt.from(20),
    playCount: BigInt.from(128000),
    subscribed: true,
    subscribedCount: BigInt.from(52000),
    shareCount: BigInt.from(340),
    commentCount: BigInt.from(88),
    tags: const <String>['华语', '流行'],
  );

  @override
  Future<List<rust.SongDto>> crateApiLibraryPlaylistSongs({
    required BigInt playlistId,
  }) async => <rust.SongDto>[
    for (var i = 1; i <= 20; i++)
      fakeSong(id: 500 + i, name: '华语热歌$i', artist: i.isOdd ? '周杰伦' : '林俊杰'),
  ];

  @override
  Future<rust.CommentPage> crateApiDetailComments({
    required String kind,
    required BigInt resourceId,
    required int limit,
    required int offset,
  }) async => rust.CommentPage(
    threadId: 'A_PL_0_24381616',
    comments: <rust.Comment>[],
    total: BigInt.zero,
    hasMore: false,
  );

  @override
  Future<rust.CommentStats> crateApiDetailCommentStats({
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

/// 首帧后 push 歌单详情(与真实入口一致: 页面画在 Navigator 里)。
class _RouteHost extends StatefulWidget {
  const _RouteHost();

  @override
  State<_RouteHost> createState() => _RouteHostState();
}

class _RouteHostState extends State<_RouteHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showPlaylistDetail(
          context,
          playlistId: BigInt.from(24381616),
          name: '华语流行精选',
          loggedIn: true,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

Future<void> _pumpPage(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          ContentWidthLimit(child: child ?? const SizedBox.shrink()),
      home: const _RouteHost(),
    ),
  );
  // 路由转场 300ms + 详情/曲目两次假 future 落位
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 筛选框当前是否拿到了焦点(焦点在 TextField 自己的 FocusNode 上)
bool _filterFocused(WidgetTester tester) {
  final field = tester.widget<TextField>(find.byType(TextField));
  return field.focusNode?.hasFocus ?? false;
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeRustApi()));

  testWidgets('单列: AppBar 有常驻搜索按钮, 滚到曲目中段后仍在', (tester) async {
    await _pumpPage(tester, const Size(360, 800));

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('搜索本页'),
      ),
      findsOneWidget,
    );

    // 往下滚过筛选条(曲目很长), 按钮仍在 AppBar 里
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('搜索本页'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('单列: 点搜索按钮把筛选条滚回来并让筛选框获得焦点', (tester) async {
    await _pumpPage(tester, const Size(360, 800));

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    // 筛选条已经滚出视野(sliver 不再构建它) —— 这正是需要常驻搜索按钮的场景
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byTooltip('搜索本页'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    expect(_filterFocused(tester), isTrue);
    // 筛选框重新落在视口内(ensureVisible 的效果)
    final fieldRect = tester.getRect(find.byType(TextField));
    expect(fieldRect.top, greaterThanOrEqualTo(0));
    expect(fieldRect.bottom, lessThanOrEqualTo(800));
  });

  testWidgets('双列: 右栏筛选框同样由 AppBar 搜索按钮聚焦', (tester) async {
    await _pumpPage(tester, const Size(1280, 720));

    await tester.drag(
      find.byKey(const Key('playlist-detail-songs-column')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: '右栏筛选条已滚出视野');

    await tester.tap(find.byTooltip('搜索本页'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(_filterFocused(tester), isTrue);
  });
}
