// 播客(电台)详情页内双列(方案 A · S2)的几何回归 —— 与歌单详情同构。
//
// 口径(见 lib/src/detail/podcast_detail_page.dart 的 _buildTwoColumnBody 与
// lib/src/layout.dart 的「页内双列」小节):
//   · 窗口 >= 900x560 ⇒ body 切成 左 300 / 间距 12 / 右 528, 两列各自滚动;
//   · 壳层 ContentWidthLimit 把 body 限宽到 840 并居中, 所以 1280 窗口下
//     左栏 left = (1280 - 840) / 2 = 220, 右栏右边界 = 220 + 840;
//   · 其余尺寸(840 及以下 / 高度不足 / 手机横屏)走**原来的单列分支**, 几何零变化。
//
// 断言的是实际渲染矩形(tester.getRect), 不是 widget 树形状。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail/podcast_detail_page.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;

import 'support/fakes.dart';

const Key _infoColumn = Key('podcast-detail-info-column');
const Key _programsColumn = Key('podcast-detail-programs-column');

final rust.PodcastRadio _radio = rust.PodcastRadio(
  id: BigInt.from(42666),
  name: '硬地电台',
  coverUrl: null,
  description: '独立音乐人的访谈与现场, 每周一期。',
  djName: '主播小林',
  programCount: BigInt.from(8),
  playCount: BigInt.from(523000),
);

/// 播客详情页只有命令式入口且数据直连 FFI, 这里垫最小一套(节目列表 + 评论)。
class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('双列测试未覆盖 ${invocation.memberName}');

  @override
  Future<List<rust.PodcastProgramDto>> crateApiPodcastPrograms({
    required BigInt radioId,
    required int limit,
    required int offset,
  }) async => <rust.PodcastProgramDto>[
    for (var i = 1; i <= 8; i++)
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
  Future<rust.CommentPage> crateApiComments({
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
  Future<rust.CommentStats> crateApiCommentStats({
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

/// 按给定窗口尺寸渲染: 外面套真实壳层的 ContentWidthLimit(宽档把 body 限到 840)。
Future<void> _pumpPage(
  WidgetTester tester,
  Size size, {
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) {
        final limited = ContentWidthLimit(
          child: child ?? const SizedBox.shrink(),
        );
        if (textScale == 1.0) return limited;
        return MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: limited,
        );
      },
      home: const _RouteHost(),
    ),
  );
  // 路由转场 300ms + 节目/评论两次假 future 落位
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 单列分支的唯一滚动容器(整个 body 一个 CustomScrollView)。
Rect _singleScrollRect(WidgetTester tester) {
  final finder = find.byType(CustomScrollView);
  expect(finder, findsOneWidget, reason: '单列分支应该只有 body 这一个 CustomScrollView');
  return tester.getRect(finder);
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeRustApi()));

  testWidgets('1280x720: 左 300 / 间距 12 / 右 528, 且整体落在居中 840 内容区', (
    tester,
  ) async {
    await _pumpPage(tester, const Size(1280, 720));

    final left = tester.getRect(find.byKey(_infoColumn));
    final right = tester.getRect(find.byKey(_programsColumn));

    // 内容区左边 = (1280 - 840) / 2 = 220(壳层限宽居中)
    expect(left.left, (1280 - kContentMaxWidth) / 2);
    expect(left.width, kTwoColumnListWidth, reason: '左栏固定 300');
    expect(right.left - left.right, kTwoColumnGap, reason: '两栏间距 12');
    expect(
      right.width,
      kContentMaxWidth - kTwoColumnListWidth - kTwoColumnGap,
      reason: '右栏吃掉剩余宽(528)',
    );
    expect(right.right, left.left + kContentMaxWidth, reason: '两栏正好填满 840');
  });

  testWidgets('1280x720: 两列顶部对齐(AppBar 之下同一条线)', (tester) async {
    await _pumpPage(tester, const Size(1280, 720));
    final left = tester.getRect(find.byKey(_infoColumn));
    final right = tester.getRect(find.byKey(_programsColumn));
    expect(left.top, right.top, reason: '双列必须顶部对齐');
    expect(
      left.top,
      tester.getRect(find.byType(AppBar)).bottom,
      reason: '两列都从 AppBar 下沿开始',
    );
    // AppBar 仍整宽: 不跟着左栏缩
    expect(tester.getRect(find.byType(AppBar)).width, kContentMaxWidth);
  });

  testWidgets('840x800: 仍单列铺满(与改造前几何一致)', (tester) async {
    await _pumpPage(tester, const Size(840, 800));
    expect(find.byKey(_infoColumn), findsNothing);
    expect(find.byKey(_programsColumn), findsNothing);
    final rect = _singleScrollRect(tester);
    expect(rect.left, 0);
    expect(rect.width, kContentMaxWidth, reason: '单列必须铺满内容区');
  });

  testWidgets('900x560(双列下界)双列, 899x800 与 900x559 单列', (tester) async {
    await _pumpPage(tester, const Size(900, 560));
    expect(find.byKey(_infoColumn), findsOneWidget);
    expect(find.byKey(_programsColumn), findsOneWidget);

    await _pumpPage(tester, const Size(899, 800));
    expect(find.byKey(_infoColumn), findsNothing, reason: '宽度差 1 就走单列');

    await _pumpPage(tester, const Size(900, 559));
    expect(find.byKey(_infoColumn), findsNothing, reason: '高度差 1 就走单列');
  });

  testWidgets('780x360(手机横屏): 高度判据生效, 仍单列', (tester) async {
    await _pumpPage(tester, const Size(780, 360));
    expect(find.byKey(_infoColumn), findsNothing);
    final rect = _singleScrollRect(tester);
    expect(rect.left, 0);
    expect(rect.width, 780);
  });

  testWidgets('300x640 @1.25 字号: 仍单列且不竖溢', (tester) async {
    await _pumpPage(tester, const Size(300, 640), textScale: 1.25);
    expect(find.byKey(_infoColumn), findsNothing);
    final rect = _singleScrollRect(tester);
    expect(rect.width, 300);
    expect(tester.takeException(), isNull);
  });
}
