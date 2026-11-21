// 播客(电台)详情页的「常驻搜索」入口(2026-11-22 用户反馈第 2 条)。
//
// 口径见 lib/src/detail/podcast_detail_page.dart 的 AppBar actions / _focusFilter:
//   · AppBar 首个动作是 Icons.search(tooltip「搜索本页」);
//   · 节目列表滚到中段后按钮仍在;
//   · 点它把筛选条滚进视野并让筛选框获得焦点(单列与双列右栏都生效)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail/podcast_detail_page.dart';
import 'package:minincm/src/layout.dart' show ContentWidthLimit;
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;

import 'support/fakes.dart';

final rust.PodcastRadio _radio = rust.PodcastRadio(
  id: BigInt.from(42666),
  name: '硬地电台',
  coverUrl: null,
  description: '独立音乐人的访谈与现场, 每周一期。',
  djName: '主播小林',
  djId: BigInt.from(9001),
  programCount: BigInt.from(20),
  playCount: BigInt.from(523000),
  subCount: BigInt.from(4321),
);

/// 播客详情页只有命令式入口且数据直连 FFI, 这里垫最小一套(节目列表 + 评论)。
class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('播客详情搜索入口测试未覆盖 ${invocation.memberName}');

  @override
  Future<List<rust.PodcastProgramDto>> crateApiPodcastPodcastPrograms({
    required BigInt radioId,
    required int limit,
    required int offset,
  }) async => <rust.PodcastProgramDto>[
    for (var i = 1; i <= 20; i++)
      rust.PodcastProgramDto(
        id: BigInt.from(900 + i),
        name: '第 $i 期 · 独立音乐现场',
        coverUrl: null,
        durationMs: BigInt.from(1800000),
        djName: '主播小林',
        radioId: radioId,
        radioName: '硬地电台',
        description: '本期聊独立音乐。',
        song: fakeSong(id: 700 + i, name: '第 $i 期 · 独立音乐现场'),
      ),
  ];

  @override
  Future<rust.CommentPage> crateApiDetailComments({
    required String kind,
    required BigInt resourceId,
    required int limit,
    required int offset,
  }) async => rust.CommentPage(
    threadId: 'A_DJ_0_42666',
    comments: <rust.Comment>[],
    total: BigInt.zero,
    hasMore: false,
  );

  @override
  Future<rust.CommentStats> crateApiDetailCommentStats({
    required String threadId,
  }) async => rust.CommentStats(
    threadId: threadId,
    resourceId: BigInt.from(42666),
    commentCount: BigInt.zero,
    commentCountDesc: '0',
    shareCount: BigInt.zero,
    likedCount: BigInt.zero,
    liked: false,
    musicianSaidCount: BigInt.zero,
    commentUpgraded: false,
  );
}

/// 首帧后 push 播客详情(与真实入口一致: 页面画在 Navigator 里)。
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
      unawaited(showPodcastDetail(context, radio: _radio));
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
  // 路由转场 300ms + 节目/评论两次假 future 落位
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

  testWidgets('单列: AppBar 有常驻搜索按钮, 滚到节目中段后仍在', (tester) async {
    await _pumpPage(tester, const Size(360, 800));

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('搜索本页'),
      ),
      findsOneWidget,
    );

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
    final fieldRect = tester.getRect(find.byType(TextField));
    expect(fieldRect.top, greaterThanOrEqualTo(0));
    expect(fieldRect.bottom, lessThanOrEqualTo(800));
  });

  testWidgets('双列: 右栏筛选框同样由 AppBar 搜索按钮聚焦', (tester) async {
    await _pumpPage(tester, const Size(1280, 720));

    await tester.drag(
      find.byKey(const Key('podcast-detail-programs-column')),
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
