// 歌单详情的**内嵌形态**(embedded)回归: 主从分栏右栏专用。
//
// 口径(见 lib/src/detail/playlist_detail_page.dart 的 build):
//   · 右栏只有 420 宽 ⇒ 没有 AppBar、没有返回箭头(否则是"返回箭头退整页"的错语义),
//     双列判据让位(按窗口 1280 会切出 300+12+528 ⇒ 竖溢), 永远单列;
//   · 内容/滚动/四态/动作(收藏·管理·分享)一个不少 —— 只是位置从 AppBar 挪到顶部一行;
//   · push 出来的整页形态(窄/中档, 以及"从压上来的页里点详情")**零变化**。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail/playlist_detail_page.dart';
import 'package:minincm/src/detail_pane.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;

import 'support/fakes.dart';

const Key _infoColumn = Key('playlist-detail-info-column');
const Key _songsColumn = Key('playlist-detail-songs-column');

class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('内嵌形态测试未覆盖 ${invocation.memberName}');

  @override
  Future<BigInt> crateApiMyUid() async => BigInt.from(1822714196);

  @override
  Future<rust.PlaylistDetail> crateApiPlaylistDetail({
    required BigInt playlistId,
  }) async => rust.PlaylistDetail(
    id: BigInt.from(24381616),
    name: '华语流行精选',
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
    comments: <rust.Comment>[],
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

/// 首帧后按**真实入口**打开歌单详情: [registerHost] = 是否有右栏宿主(HomePage 那层)。
class _Host extends StatefulWidget {
  const _Host({required this.registerHost});

  final bool registerHost;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    if (widget.registerHost) attachDetailPaneHost();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showPlaylistDetail(
          context,
          playlistId: BigInt.from(24381616),
          name: '华语流行精选',
          loggedIn: true,
          currentTrackId: BigInt.from(501),
          currentPlaylistId: BigInt.from(24381616),
        ),
      );
    });
  }

  @override
  void dispose() {
    if (widget.registerHost) detachDetailPaneHost();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: widget.registerHost
        ? DetailPaneSplit(master: (context, _) => const SizedBox.expand())
        // 没有右栏宿主: 详情会 push 成一整页, 这里只需一个空壳
        : const SizedBox.shrink(),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required bool registerHost,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          ContentWidthLimit(child: child ?? const SizedBox.shrink()),
      home: _Host(registerHost: registerHost),
    ),
  );
  // 帧后 push/填槽 + 详情/曲目两次假 future 落位
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeRustApi()));

  setUp(() {
    detailPaneSlot.value = null;
  });

  testWidgets('1280x720 右栏形态: 无 AppBar / 无返回箭头, 内容与滚动照旧', (tester) async {
    await _pump(tester, size: const Size(1280, 720), registerHost: true);

    expect(detailPaneSlot.value, isNotNull, reason: '宽档 + 宿主 ⇒ 应该填右栏');
    expect(find.byType(DetailPaneSurface), findsOneWidget);
    expect(find.byType(AppBar), findsNothing, reason: '右栏没有 AppBar');
    expect(
      find.byType(BackButton),
      findsNothing,
      reason: '右栏不能出现"返回箭头退整页"的错语义',
    );
    // 内容照旧: 头部卡片(创建者) + 曲目行 + 筛选条
    expect(find.text('创建者: 云音乐编辑部'), findsOneWidget);
    expect(find.text('华语热歌1'), findsOneWidget);
    expect(find.text('筛选本页曲目'), findsOneWidget);
    // 动作一个不少(从 AppBar 挪到顶部一行)
    expect(find.byTooltip('分享'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    // 滚动容器仍只有曲目那一个 CustomScrollView; 双列分支让位(右栏 420 宽)
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byKey(_infoColumn), findsNothing, reason: '内嵌形态永远单列');
    expect(tester.takeException(), isNull);
  });

  testWidgets('1280x720 右栏形态: 右栏只有 kDetailPaneWidth 宽, 不溢出', (tester) async {
    await _pump(tester, size: const Size(1280, 720), registerHost: true);
    final pane = tester.getRect(find.byType(DetailPaneSurface));
    expect(pane.width, kDetailPaneWidth);
    // 曲目滚动区落在右栏之内(左右都不越界)
    final scroll = tester.getRect(find.byType(CustomScrollView));
    expect(scroll.left, greaterThanOrEqualTo(pane.left));
    expect(scroll.right, lessThanOrEqualTo(pane.right + 0.01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('1280x720 无宿主 ⇒ 仍 push 整页形态(AppBar + 双列, 零变化)', (tester) async {
    await _pump(tester, size: const Size(1280, 720), registerHost: false);

    expect(detailPaneSlot.value, isNull);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
    // push 形态沿用既有双列(左 300 / 右 528): 这才是 S1 锁住的几何
    expect(find.byKey(_infoColumn), findsOneWidget);
    expect(find.byKey(_songsColumn), findsOneWidget);
    expect(tester.getRect(find.byKey(_infoColumn)).width, kTwoColumnListWidth);
  });
}
