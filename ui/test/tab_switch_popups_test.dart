// 切底部 tab 收起浮层(U-01) / 队列面板关自己那条 route(U-02) 的回归.
//
// 背景(用户反馈): 底部导航/播放条住在 Navigator **之外**, 弹层开着时仍可点 tab;
// 而弹层是 modal route, 不会随 tab 切换自己消失, 会一直挂在旧页面上。
// 以前 `_onTabSelected` 里逐类手写(`dismissLoginSheet()` + `_queueUI.close()`),
// 只补了登录弹层与队列面板两类, 还漏 5 类。
//
// 现在只有一个入口: `app_shell.dart` 的 `dismissAllPopups()` —— 按
// `NcmRouteObserver` 的浮层登记表逐条摘除(is sheet 还是 dialog 不重要, PopupRoute 就收)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/app_shell.dart'
    show
        NcmRouteObserver,
        dismissAllPopups,
        modalRouteOpen,
        openPopups,
        pageDepth;
import 'package:minincm/src/detail_pane.dart'
    show DetailPaneRequest, closeDetailPane, detailPaneSlot;
import 'package:minincm/src/home/queue_sheet_controller.dart';
import 'package:minincm/src/home/song_action_wiring.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/song_actions.dart'
    show SongActionHost, SongActionSource, showSongActionsSheet;
import 'package:minincm/src/song_share.dart' show showSongShareSheet;
import 'package:minincm/src/update_checker.dart' show UpdateInfo;
import 'package:minincm/src/update_dialog.dart' show showUpdateDialog;

import 'support/fakes.dart';
import 'support/nav_chrome.dart';

/// 根壳(与生产 MiniNcmApp 同一条装配): 观察者 + Navigator 之外的播放条/导航栏。
///
/// bootstrap 会打平台通道/Rust(测试里失败进错误态)并起 500ms 轮询 Timer,
/// 所以只 pump 固定时长, **不用 pumpAndSettle**。
Future<void> pumpHomeShell(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  addTearDown(() => playerBarSlot.value = null);
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [NcmRouteObserver()],
      builder: (context, child) =>
          PlayerBarHost(content: child ?? const SizedBox.shrink()),
      home: const HomePage(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

/// 切到「我的」tab(宽档走左侧 Rail、窄档走底部 Bar, 断言用档位中立的查找器)。
Future<void> switchToMine(WidgetTester tester) async {
  await tester.tap(
    find.descendant(of: navChromeFinder, matching: find.text('我的')),
  );
  await tester.pump(); // _onTabSelected → dismissAllPopups
  await tester.pump(const Duration(milliseconds: 400)); // 收起动画
}

/// 当前真的还挂在栈上的浮层(排除已随宿主销毁的旧 route)。
List<Route<dynamic>> livePopups() =>
    openPopups.where((r) => r.isActive).cast<Route<dynamic>>().toList();

void main() {
  setUp(() {
    // 队列面板首次展开会弹「左滑移除」提示; 这里只关心收起语义, 预置"已确认"
    AppSettings.instance.queueSwipeHintDismissed = true;
    // 壳层的栈计数是全局静态量(一条 app 生命周期一份): 上一个用例的树是被直接
    // 换掉的(didPop 不会来), 不清零会让下一个用例从 2 起 ⇒ 底部导航因
    // `pageDepth > 1` 直接不渲染。
    pageDepth.value = 0;
    modalRouteOpen.value = false;
  });

  testWidgets('dismissAllPopups: 一次收掉压着的所有浮层(sheet 上叠 dialog)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [NcmRouteObserver()],
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => unawaited(
                  showModalBottomSheet<void>(
                    context: ctx,
                    builder: (sheetCtx) => Center(
                      child: TextButton(
                        onPressed: () => unawaited(
                          showDialog<void>(
                            context: sheetCtx,
                            builder: (_) =>
                                const AlertDialog(title: Text('d-1')),
                          ),
                        ),
                        child: const Text('open-dialog'),
                      ),
                    ),
                  ),
                ),
                child: const Text('open-sheet'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open-sheet'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-dialog'));
    await tester.pumpAndSettle();
    expect(find.text('d-1'), findsOneWidget);
    expect(livePopups(), hasLength(2));

    expect(dismissAllPopups(), 2);
    await tester.pumpAndSettle();
    expect(find.text('d-1'), findsNothing);
    expect(find.text('open-dialog'), findsNothing);
    expect(livePopups(), isEmpty);
  });

  testWidgets('U-02: 队列面板上压着「清空确认框」时切 tab ⇒ 两者都关', (tester) async {
    await pumpHomeShell(tester);
    final depthBefore = pageDepth.value;

    // 先把 HomePage 的 context 取好: controller.open() 是 unawaited 的,
    // 在它里面调 tester.element 会落在 TestAsyncUtils 的守卫之外。
    final homeContext = tester.element(find.byType(HomePage));
    final queue = PlayQueue<rust.SongDto>()
      ..setAll([fakeSong(id: 1, name: '第一首'), fakeSong(id: 2, name: '第二首')]);
    final controller = QueueSheetController(
      contextOf: () => homeContext,
      isMounted: () => true,
      queue: queue,
      libraryTitleOf: () => null,
      toast: (_) {},
      playSong: (song, {bool explicit = false}) async {},
      stopPlayback: () async {},
      clearSavedState: () async {},
      setUserStopped: (_) {},
      heartMode: () async {},
      leaveHeartMode: () {},
      syncActionState: () async {},
    );
    addTearDown(controller.dispose);

    unawaited(controller.open());
    await tester.pump(); // 走完 `await _maybeShowSwipeHint()` 的微任务
    await tester.pump(); // push 路由
    await tester.pump(const Duration(milliseconds: 400)); // 滑入动画
    expect(find.text('当前播放队列'), findsOneWidget);

    // 面板里点「清空队列」⇒ 其上弹出二次确认框(这一层就是 U-02 的触发条件)
    await tester.tap(find.byTooltip('清空队列'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('清空播放队列?'), findsOneWidget);
    expect(livePopups(), hasLength(2));

    await switchToMine(tester);

    expect(find.text('清空播放队列?'), findsNothing, reason: '确认框要关');
    expect(find.text('当前播放队列'), findsNothing, reason: '面板也要关(以前只关确认框)');
    expect(livePopups(), isEmpty);
    expect(pageDepth.value, depthBefore, reason: '浮层不算一层, 不许误退页面');
    expect(navSelectedIndex(tester), isNot(0), reason: 'tab 真的切过去了');
    expect(controller.isOpen, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('U-01: 歌曲动作面板打开时切 tab ⇒ 关闭且不误退页面', (tester) async {
    await pumpHomeShell(tester);
    final depthBefore = pageDepth.value;
    final host = SongActionHost(
      loggedIn: false,
      isLiked: (_) => false,
      toggleLike: (_) async {},
      playNext: (_) async {},
      addToPlaylist: (_) async {},
      share: (_) async {},
      comments: (_) async {},
      openArtist: (_) async {},
      openAlbum: (_) async {},
      download: (_) async {},
    );
    unawaited(
      showSongActionsSheet(
        tester.element(find.byType(HomePage)),
        fakeSong(id: 3, name: '晴天'),
        host,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('歌曲操作'), findsOneWidget);

    await switchToMine(tester);

    expect(find.text('歌曲操作'), findsNothing);
    expect(pageDepth.value, depthBefore);
    expect(livePopups(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('U-01: 分享面板打开时切 tab ⇒ 关闭', (tester) async {
    await pumpHomeShell(tester);
    final depthBefore = pageDepth.value;
    unawaited(
      showSongShareSheet(
        tester.element(find.byType(HomePage)),
        song: fakeSong(id: 4, name: '晴天'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(livePopups(), hasLength(1));

    await switchToMine(tester);

    expect(livePopups(), isEmpty);
    expect(pageDepth.value, depthBefore);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('U-03: home 歌曲动作装配的分享面板(wiring 入口)切 tab ⇒ 关闭', (tester) async {
    // 这条盯的是**第二批迁移的 home 入口**(song_action_wiring 的 `_showShareSong`):
    // 它以前直连 showModalBottomSheet, 只能靠"恰好是 PopupRoute"被兜住; 现在经
    // showAppSheet ⇒ buildAppSheetRoute, 必须出现在登记表里并被 dismissAllPopups 收掉。
    await pumpHomeShell(tester);
    final depthBefore = pageDepth.value;
    final homeContext = tester.element(find.byType(HomePage));
    final wiring = SongActionWiring(
      contextOf: () => homeContext,
      toast: (_) {},
      isMounted: () => true,
      loggedIn: () => false,
      isLiked: (_) => false,
      markLiked: (_, _) {},
      rebuild: () {},
      queue: PlayQueue<rust.SongDto>(),
      playSongsList: (songs, index) async {},
      currentSong: () => null,
      playSource: () => SongActionSource.other,
      syncActionState: () async {},
      openPlaylist: (_) async {},
    );
    unawaited(wiring.buildHost().share(fakeSong(id: 5, name: '晴天')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('分享到动态'), findsOneWidget);
    expect(
      livePopups().single,
      isA<ModalBottomSheetRoute<void>>(),
      reason: '走 showAppSheet/builder 造的是可登记的 ModalBottomSheetRoute',
    );

    await switchToMine(tester);

    expect(find.text('分享到动态'), findsNothing);
    expect(livePopups(), isEmpty);
    expect(pageDepth.value, depthBefore, reason: '浮层不算一层, 不许误退页面');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('U-01: 更新弹窗(dialog)打开时切 tab ⇒ 关闭', (tester) async {
    await pumpHomeShell(tester);
    final depthBefore = pageDepth.value;
    unawaited(
      showUpdateDialog(
        tester.element(find.byType(HomePage)),
        const UpdateInfo(latest: 'v9.9.9', current: 'v0.0.0', isNewer: true),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('发现新版本'), findsOneWidget);

    await switchToMine(tester);

    expect(find.textContaining('发现新版本'), findsNothing);
    expect(pageDepth.value, depthBefore);
    expect(livePopups(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('主从分栏: 右栏详情里弹 sheet 仍被登记, 切 tab 仍收起', (tester) async {
    // 方案 B · S4 的关键取舍: 右栏**不是路由**, 所以右栏里弹的 sheet 走的是**根**
    // Navigator ⇒ 登记面与改动前完全一致(不靠嵌套 Navigator 的 observer, 不会双计
    // pageDepth)。这条用例就是那句话的证据: 右栏里弹的 sheet 既被登记也被切 tab 收掉,
    // 且页面层数不变。
    await pumpHomeShell(tester);
    final depthBefore = pageDepth.value;
    addTearDown(() {
      detailPaneSlot.value = null;
    });
    detailPaneSlot.value = DetailPaneRequest(
      key: 'pl-1',
      builder: (paneContext) => Center(
        child: TextButton(
          onPressed: () => unawaited(
            showModalBottomSheet<void>(
              context: paneContext,
              builder: (_) => const Center(child: Text('右栏里的面板')),
            ),
          ),
          child: const Text('open-pane-sheet'),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('open-pane-sheet'));
    await tester.pumpAndSettle();

    expect(find.text('右栏里的面板'), findsOneWidget);
    expect(livePopups(), hasLength(1), reason: '右栏里的 sheet 仍挂在根 Navigator 上');
    expect(modalRouteOpen.value, isTrue);
    expect(pageDepth.value, depthBefore, reason: '浮层不算一层');

    await switchToMine(tester);

    expect(find.text('右栏里的面板'), findsNothing, reason: '切 tab 照旧收起');
    expect(livePopups(), isEmpty);
    expect(detailPaneSlot.value, isNull, reason: '切 tab 一并清掉右栏');
    expect(pageDepth.value, depthBefore, reason: '右栏与浮层都不算一层, 不许误退页面');
    expect(navSelectedIndex(tester), 3, reason: 'tab 真的切过去了');
    closeDetailPane();
    await tester.pumpWidget(const SizedBox());
  });
}
