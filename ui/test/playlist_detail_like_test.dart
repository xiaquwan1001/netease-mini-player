// 歌单详情页的红心(D05/D06, 2026-11-25 审计)。
//
// 口径(见 lib/src/detail/playlist_detail_page.dart 的 _toggleLike / didUpdateWidget):
//   · D05: 详情页红心不再自己 `rust.setLiked` 一遍, 而是走主页注入的动作宿主
//     (`AppActions` 的 `toggleLike` = wiring 的 `toggleLikeFor`) —— 与同一行
//     "..."菜单里的喜欢是同一个实现: 乐观更新 + 失败回滚 + 通知栏同步;
//   · D06: 页面内的红心快照在入参 `likedIds` 变化时跟上(分栏里重新选中同一个歌单
//     会拿新的入参重建本页), 不许两份状态各说各话。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail/playlist_detail_page.dart';
import 'package:minincm/src/detail_pane.dart';
import 'package:minincm/src/layout.dart' show ContentWidthLimit;
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;
import 'package:minincm/src/song_actions.dart' show AppActions, SongActionHost;

import 'support/fakes.dart';

final BigInt _playlistId = BigInt.from(24381616);
final BigInt _firstSongId = BigInt.from(501);

/// 详情页只有命令式入口且数据直连 FFI, 这里垫最小一套(详情 / 曲目 / 统计)。
///
/// 本文件只有一条红线要盯: **红心不能越过动作宿主自己去写**(D05), 所以
/// `crateApiLibrarySetLiked` 记数 —— 修复后它必须是 0。
class _FakeRustApi implements RustLibApi {
  int setLikedCalls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('歌单红心测试未覆盖 ${invocation.memberName}');

  @override
  Future<BigInt> crateApiSocialMyUid() async => BigInt.from(1822714196);

  @override
  Future<bool> crateApiLibrarySetLiked({
    required BigInt trackId,
    required bool liked,
  }) async {
    setLikedCalls += 1;
    return true;
  }

  @override
  Future<rust.PlaylistDetail> crateApiDetailPlaylistDetail({
    required BigInt playlistId,
  }) async => rust.PlaylistDetail(
    id: _playlistId,
    name: '华语流行精选',
    coverUrl: null,
    description: '每日更新的华语流行精选。',
    creatorName: '云音乐编辑部',
    creatorId: BigInt.from(999999999),
    trackCount: BigInt.from(6),
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
    for (var i = 1; i <= 6; i++)
      fakeSong(id: 500 + i, name: '华语热歌$i', artist: '周杰伦'),
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
    resourceId: _playlistId,
    commentCount: BigInt.zero,
    commentCountDesc: '0',
    shareCount: BigInt.zero,
    likedCount: BigInt.zero,
    liked: false,
    musicianSaidCount: BigInt.zero,
    commentUpgraded: false,
  );
}

late _FakeRustApi _api;

/// 假动作宿主: 只记录"喜欢"被谁点到了, 并让 future 挂起(验乐观更新)。
class _FakeHost {
  final Completer<void> pending = Completer<void>();
  final List<BigInt> toggled = <BigInt>[];

  late final SongActionHost host = SongActionHost(
    loggedIn: true,
    isLiked: (id) => false,
    toggleLike: (song) {
      toggled.add(song.id);
      return pending.future;
    },
    playNext: (_) async {},
    addToPlaylist: (_) async {},
    share: (_) async {},
    comments: (_) async {},
    openArtist: (_) async {},
    openAlbum: (_) async {},
    download: (_) async {},
  );
}

/// 宿主壳: 首帧后按真实入口打开详情。
///
/// [withPaneHost] = true 时注册主从分栏宿主(1280 宽 ⇒ 详情填右栏, 不 push),
/// 右栏里再点"重新打开"会拿**新的** `likedIds` 重建同一个 State(D06 路径)。
class _Host extends StatefulWidget {
  const _Host({
    required this.withPaneHost,
    required this.likedIds,
    this.liveLiked,
  });

  final bool withPaneHost;
  final Set<BigInt> likedIds;

  /// 非 null 时给详情页传 `likedOf` 访问器, 指向这一份"宿主真相"(D06 实时回流)。
  final Set<BigInt>? liveLiked;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  Set<BigInt> _likedIds = const <BigInt>{};

  @override
  void initState() {
    super.initState();
    _likedIds = widget.likedIds;
    if (widget.withPaneHost) attachDetailPaneHost();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_open());
    });
  }

  @override
  void dispose() {
    if (widget.withPaneHost) detachDetailPaneHost();
    super.dispose();
  }

  Future<void> _open() => showPlaylistDetail(
    context,
    playlistId: _playlistId,
    name: '华语流行精选',
    loggedIn: true,
    likedIds: _likedIds,
    likedOf: widget.liveLiked == null
        ? null
        : (id) => widget.liveLiked!.contains(id),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(
          onPressed: () {
            // 分栏里"重新选中同一条歌单" = 换一份入参重建右栏(不是新 State)
            setState(() => _likedIds = {_firstSongId});
            unawaited(_open());
          },
          child: const Text('重新打开'),
        ),
        Expanded(
          child: widget.withPaneHost
              ? DetailPaneSplit(master: (context, _) => const SizedBox.expand())
              : const SizedBox.shrink(),
        ),
      ],
    ),
  );
}

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required bool withPaneHost,
  required Set<BigInt> likedIds,
  bool withActions = false,
  _FakeHost? host,
  Set<BigInt>? liveLiked,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final app = MaterialApp(
    builder: (context, child) {
      final content = ContentWidthLimit(
        child: child ?? const SizedBox.shrink(),
      );
      // 生产里 AppActions 挂在 Navigator 之上(见 app_shell.dart), pushed route 也取得到
      return withActions
          ? AppActions(host: host!.host, child: content)
          : content;
    },
    home: _Host(
      withPaneHost: withPaneHost,
      likedIds: likedIds,
      liveLiked: liveLiked,
    ),
  );
  await tester.pumpWidget(app);
  for (var i = 0; i < 24; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 第 1 首曲目行的红心是否是"已喜欢"形态
bool _firstRowLiked(WidgetTester tester) =>
    find.byTooltip('取消喜欢').evaluate().isNotEmpty;

void main() {
  setUpAll(() => RustLib.initMock(api: _api = _FakeRustApi()));

  setUp(() {
    _api.setLikedCalls = 0;
    detailPaneSlot.value = null;
  });

  testWidgets('D05: 详情页红心走动作宿主(不是自己再写一次 setLiked)', (tester) async {
    final fake = _FakeHost();
    await _pump(
      tester,
      size: const Size(360, 800),
      withPaneHost: false,
      likedIds: const <BigInt>{},
      withActions: true,
      host: fake,
    );

    // 第一行红心可点(未喜欢形态)
    expect(find.byTooltip('喜欢'), findsWidgets);
    await tester.tap(find.byTooltip('喜欢').first);
    await tester.pump();

    expect(fake.toggled, <BigInt>[_firstSongId], reason: '红心必须交给宿主(D05)');
    expect(_firstRowLiked(tester), isTrue, reason: '乐观更新: 请求还没回来就点亮');
    expect(_api.setLikedCalls, 0, reason: '页面不许自己调 setLiked 绕开宿主的通知栏同步');

    fake.pending.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('D06: 入参红心集合变化时页面快照跟上', (tester) async {
    await _pump(
      tester,
      size: const Size(1280, 720),
      withPaneHost: true,
      likedIds: const <BigInt>{},
    );
    expect(_firstRowLiked(tester), isFalse);

    // 分栏里重新选中同一条歌单: 新入参 likedIds={501} 重建同一个 State
    await tester.tap(find.text('重新打开'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(_firstRowLiked(tester), isTrue, reason: '快照没跟上入参 = 两份状态各说各话');
    expect(tester.takeException(), isNull);
  });

  testWidgets('D06: 宿主红心变了(播放条/菜单改的)时详情页跟着回流', (tester) async {
    // 模拟主页的"我喜欢的音乐"集合: 详情页只看它, 不看自己的快照
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final live = <BigInt>{};
    final key = GlobalKey<_LiveLikedShellState>();
    await tester.pumpWidget(_LiveLikedShell(key: key, live: live));
    for (var i = 0; i < 24; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(_firstRowLiked(tester), isFalse);

    // 用户在播放条上点亮这首歌(宿主的 _markLiked → setState → 分栏重建)
    key.currentState!.markLikedExternally(_firstSongId);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(_firstRowLiked(tester), isTrue, reason: '宿主的红心变化必须回流到详情页(D06 实时回流)');
    expect(tester.takeException(), isNull);
  });
}

/// 最小"主页"壳: 持有红心集合(= 主页 _liked), 并以访问器形式传给详情页。
class _LiveLikedShell extends StatefulWidget {
  const _LiveLikedShell({super.key, required this.live});

  final Set<BigInt> live;

  @override
  State<_LiveLikedShell> createState() => _LiveLikedShellState();
}

class _LiveLikedShellState extends State<_LiveLikedShell> {
  @override
  void initState() {
    super.initState();
    attachDetailPaneHost();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(
        showPlaylistDetail(
          context,
          playlistId: _playlistId,
          name: '华语流行精选',
          loggedIn: true,
          // 快照仍是打开那一刻的空集合 —— 真相靠 likedOf 访问器
          likedIds: const <BigInt>{},
          likedOf: (id) => widget.live.contains(id),
        ),
      );
    });
  }

  @override
  void dispose() {
    detachDetailPaneHost();
    super.dispose();
  }

  /// 等价于主页 `_markLiked`: 改集合 + setState(分栏跟着重建)
  void markLikedExternally(BigInt id) {
    setState(() => widget.live.add(id));
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    builder: (context, child) =>
        ContentWidthLimit(child: child ?? const SizedBox.shrink()),
    home: Scaffold(
      body: DetailPaneSplit(master: (context, _) => const SizedBox.expand()),
    ),
  );
}
