// 播客(电台)详情的第四批反馈 F5(2026-11-22 晚):
//   · F5-F3: AppBar 不再显示电台名(名称只在头部卡片里);
//   · F5-F2: AppBar 评论入口把末尾的内联评论区滚进视野;
//   · F5-F4: 头部「主播」有 uid 时可点进他人主页, djId=0 时不可点;
//   · F5-收藏: 顶部 icon 从「听众」换成「收藏」, 调 setPodcastSubscribed 后按返回值切换。
//
// 口径见 lib/src/detail/podcast_detail_page.dart 的 _toggleSubscribe / _DjLine /
// _scrollToComments; 「听众」入口挪到头部卡片的「N 人收藏」。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment/comment_thread.dart' show CommentThread;
import 'package:minincm/src/detail/podcast_detail_page.dart';
import 'package:minincm/src/layout.dart' show ContentWidthLimit;
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;
import 'package:minincm/src/user/user_page.dart' show UserPage;

import 'support/fakes.dart';

/// 详情通道(podcast_radio)返回的主播 uid; 0 模拟「该通道不带」
BigInt _djId = BigInt.from(9001);

/// 收藏态/次数由 fake 掌控: 初始未收藏, 收藏数 1234
bool _subed = false;
int _subCount = 1234;

/// 收起 setPodcastSubscribed 的调用记录: [(radioId, subscribed)]
final List<(BigInt, bool)> _subCalls = <(BigInt, bool)>[];

/// 列表通道给的那份(没有收藏态/主播 uid) —— 详情页必须自己补齐
rust.PodcastRadio _listRadio({BigInt? djId, bool? subed, BigInt? subCount}) =>
    rust.PodcastRadio(
      id: BigInt.from(42666),
      name: '硬地电台',
      coverUrl: null,
      description: '独立音乐人的访谈与现场, 每周一期。',
      djName: '主播小林',
      djId: djId ?? BigInt.zero,
      programCount: BigInt.from(20),
      playCount: BigInt.from(523000),
      subed: subed,
      subCount: subCount ?? BigInt.zero,
    );

class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('播客详情 F5 测试未覆盖 ${invocation.memberName}');

  @override
  Future<BigInt> crateApiSocialMyUid() async => BigInt.from(1822714196);

  @override
  Future<rust.PodcastRadio> crateApiPodcastPodcastRadio({
    required BigInt radioId,
  }) async => rust.PodcastRadio(
    id: radioId,
    name: '硬地电台',
    coverUrl: null,
    description: '独立音乐人的访谈与现场, 每周一期。',
    djName: '主播小林',
    djId: _djId,
    programCount: BigInt.from(20),
    playCount: BigInt.from(523000),
    subed: _subed,
    subCount: BigInt.from(_subCount),
  );

  @override
  Future<bool> crateApiPodcastSetPodcastSubscribed({
    required BigInt radioId,
    required bool subscribed,
  }) async {
    _subCalls.add((radioId, subscribed));
    _subed = subscribed;
    return true;
  }

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

  // ---- 点主播后压上来的他人主页(UserPage)所需的最小数据面 ----

  @override
  Future<rust.ProfileDetail> crateApiAccountUserProfile({
    required BigInt userId,
  }) async => rust.ProfileDetail(
    userId: userId,
    nickname: '主播小林',
    signature: '',
    vip: false,
    follows: BigInt.zero,
    followeds: BigInt.zero,
    level: BigInt.zero,
  );

  @override
  Future<List<rust.Playlist>> crateApiAccountUserPlaylistsOf({
    required BigInt userId,
    required int limit,
  }) async => <rust.Playlist>[];

  @override
  Future<List<rust.FeedEventDto>> crateApiSocialUserEvents({
    required BigInt uid,
    required int limit,
    required int lastTime,
  }) async => <rust.FeedEventDto>[];
}

/// 首帧后 push 播客详情(与真实入口一致: 页面画在 Navigator 里)
class _RouteHost extends StatefulWidget {
  const _RouteHost({this.radio, this.loggedIn = true});

  final rust.PodcastRadio? radio;
  final bool loggedIn;

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
        showPodcastDetail(
          context,
          radio: widget.radio ?? _listRadio(),
          loggedIn: widget.loggedIn,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

Future<void> _pumpPage(
  WidgetTester tester,
  Size size, {
  rust.PodcastRadio? radio,
  bool loggedIn = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          ContentWidthLimit(child: child ?? const SizedBox.shrink()),
      home: _RouteHost(radio: radio, loggedIn: loggedIn),
    ),
  );
  // 路由转场 300ms + 节目/详情/评论几次假 future 落位
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeRustApi()));

  setUp(() {
    _djId = BigInt.from(9001);
    _subed = false;
    _subCount = 1234;
    _subCalls.clear();
  });

  testWidgets('AppBar 不再显示电台名(名称只在头部卡片里)', (tester) async {
    await _pumpPage(tester, const Size(360, 800));

    final appBarTitle = find.descendant(
      of: find.byType(AppBar),
      matching: find.text('硬地电台'),
    );
    expect(appBarTitle, findsNothing);
    // 头部卡片里仍有(不是把名字整个删掉)
    expect(find.text('硬地电台'), findsWidgets);
  });

  testWidgets('点评论入口把内联评论区滚进视野', (tester) async {
    await _pumpPage(tester, const Size(360, 800));

    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('查看评论'),
      ),
      findsOneWidget,
    );
    expect(find.byType(CommentThread), findsNothing, reason: '评论区在 20 期节目之后');

    await tester.tap(find.byTooltip('查看评论'));
    await tester.pumpAndSettle();

    final rect = tester.getRect(find.byType(CommentThread));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(800));
  });

  testWidgets('顶部收藏按钮: 调 FFI 后按返回值切换, 收藏数 +1', (tester) async {
    await _pumpPage(tester, const Size(360, 800));

    // 初始未收藏(详情通道说 subed=false)
    expect(find.byTooltip('收藏播客'), findsOneWidget);
    expect(find.byTooltip('取消收藏'), findsNothing);
    expect(find.text('1234 人收藏'), findsOneWidget);

    await tester.tap(find.byTooltip('收藏播客'));
    await tester.pumpAndSettle();

    expect(_subCalls, <(BigInt, bool)>[(BigInt.from(42666), true)]);
    expect(find.byTooltip('取消收藏'), findsOneWidget);
    expect(find.text('1235 人收藏'), findsOneWidget);
  });

  testWidgets('未登录: 点收藏只提示, 不发请求也不改状态', (tester) async {
    await _pumpPage(tester, const Size(360, 800), loggedIn: false);

    await tester.tap(find.byTooltip('收藏播客'));
    await tester.pumpAndSettle();

    expect(_subCalls, isEmpty, reason: '未登录不该打远端');
    expect(find.byTooltip('收藏播客'), findsOneWidget);
  });

  testWidgets('头部「主播」可点进他人主页', (tester) async {
    await _pumpPage(tester, const Size(360, 800));
    expect(find.byType(UserPage), findsNothing);

    await tester.tap(find.text('主播: 主播小林'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(UserPage), findsOneWidget);
  });

  testWidgets('主播 uid 为 0(通道不带 dj.userId)时不可点', (tester) async {
    _djId = BigInt.zero;
    await _pumpPage(tester, const Size(360, 800), radio: _listRadio());

    await tester.tap(find.text('主播: 主播小林'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(UserPage), findsNothing);
  });
}
