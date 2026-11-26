// 桌面导航常驻 + 播放条宽度口径(车道 B)的壳层回归。
//
// 背景(用户 2026-11-26 反馈「进二级页闪一下 / 内外排版重排 / 播放条边界长度变化」):
// 推入二级路由的第一帧, `_buildBottomBar` 的 `pageDepth > 1` 让位让 NavigationRail 立刻
// 消失 ⇒ 根布局 `_PlayerBarChrome` 从 Row(rail + 右列) 换成 Column ⇒ 一级页内容横向
// 跳 kRailWidth、播放条从 (窗口宽 - rail) 变成窗口宽。
//
// 口径:
//   · 桌面(Linux/Windows): 导航是**窗口常驻外壳**, 全屏页压上来也不让位;
//   · 手机(Android): 全屏页仍然让位(这里用 `debugForceNonDesktopPlatform` 复验);
//   · 桌面点导航时若有全屏页压着, 先 popUntil 回首页再切 tab(点当前 tab 也算)。
//
// 不用 pumpAndSettle: HomePage 的 bootstrap 会起 500ms 轮询 Timer, 永不 settle。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/app_shell.dart'
    show
        NcmRouteObserver,
        PlayerBarHost,
        modalRouteOpen,
        pageDepth,
        playerBarSlot;
import 'package:minincm/src/layout.dart' show kContentMaxWidth, kRailWidth;
import 'package:minincm/src/player_bar.dart'
    show
        MiniPlayerBar,
        PlayerBarActions,
        PlayerBarData,
        debugForceNonDesktopPlatform;
import 'package:minincm/src/playback.dart' show PlayerView;
import 'package:minincm/src/rust/api_all.dart' as rust;

/// 根壳(与生产同一条装配): NavigatorObserver + Navigator 之外的播放条/导航栏。
///
/// bootstrap 会打平台通道/Rust(测试里必然失败 → 错误态)并起轮询 Timer,
/// 所以只 pump 固定帧数, 退出时把树换掉停 Timer。
Future<void> pumpHome(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => playerBarSlot.value = null);
  addTearDown(() {
    pageDepth.value = 0;
    modalRouteOpen.value = false;
    debugForceNonDesktopPlatform = false;
  });
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
  addTearDown(() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } catch (_) {}
  });
}

/// 推一张整页路由(非弹层 ⇒ pageDepth 会 +1)。只 pump 固定帧数, 不 settle。
///
/// 转场时长显式置 0: Flutter 的 Material 页转场会把**被压住的旧页**也做位移
/// (实测 300ms 里首页整块向左滑 210), 那样量出来的 rect 差是动画量而非排版量 ——
/// 本用例要看的是「导航让位导致根布局换形」, 所以把动画拿掉, 只留布局。
Future<void> pushFullPage(WidgetTester tester, {int frames = 3}) async {
  final context = tester.element(find.byType(HomePage));
  unawaited(
    Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (context, _, _) => Scaffold(
          appBar: AppBar(title: const Text('二级页')),
          body: const Center(child: Text('二级页正文')),
        ),
      ),
    ),
  );
  for (var i = 0; i < frames; i += 1) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// HomePage 自己那张内容的 Scaffold(排除二级页的)。
///
/// 全屏路由落地后首页整棵子树会被 Overlay 移出 onstage(不绘制但仍布局),
/// 默认 finder 会跳过它 —— 量几何必须 skipOffstage: false。
Finder homeScaffoldFinder() => find
    .descendant(
      of: find.byType(HomePage, skipOffstage: false),
      matching: find.byType(Scaffold, skipOffstage: false),
      skipOffstage: false,
    )
    .first;

int? railSelectedIndex(WidgetTester tester) =>
    tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex;

void main() {
  setUp(() {
    // 栈计数与弹层标记是进程级静态量: 上一个用例的树被直接换掉(didPop 不会来)。
    pageDepth.value = 0;
    modalRouteOpen.value = false;
    debugForceNonDesktopPlatform = false;
  });

  testWidgets('桌面(1000x900): 推整页路由后 Rail 与内容几何逐帧不变', (tester) async {
    await pumpHome(tester, const Size(1000, 900));

    final railBefore = tester.getRect(find.byType(NavigationRail));
    final scaffoldBefore = tester.getRect(homeScaffoldFinder());
    // 宽档内容被壳层限宽居中: 右列宽 = 1000 - 80 = 920 ⇒ 左边距 80 + 40
    expect(railBefore.left, 0);
    expect(railBefore.width, kRailWidth);
    expect(scaffoldBefore.width, kContentMaxWidth);
    expect(scaffoldBefore.left, kRailWidth + (920 - kContentMaxWidth) / 2);

    await pushFullPage(tester);

    expect(pageDepth.value, 2, reason: '整页路由应让 pageDepth +1');
    expect(
      find.byType(NavigationRail),
      findsOneWidget,
      reason: '桌面导航是窗口常驻外壳, 全屏页压上来也不让位',
    );
    expect(tester.getRect(find.byType(NavigationRail)), railBefore);
    expect(
      tester.getRect(homeScaffoldFinder()),
      scaffoldBefore,
      reason: '导航不让位 ⇒ 右列不换形, 一级页内容不许横向跳',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('桌面: 全屏页压着时点 Rail「我的」⇒ 先退页再切 tab, Rail 仍在', (tester) async {
    await pumpHome(tester, const Size(1000, 900));
    expect(railSelectedIndex(tester), 1, reason: '冷启动默认落在「推荐」');

    await pushFullPage(tester);
    await tester.pump(const Duration(milliseconds: 400)); // 推入落地后点导航
    expect(pageDepth.value, 2);
    expect(find.text('二级页正文'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('我的'),
      ),
    );
    await tester.pump(); // _onTabSelected → popUntil + setState
    await tester.pump(const Duration(milliseconds: 400)); // 退出转场
    await tester.pump(const Duration(milliseconds: 16)); // 旧 route 从 overlay 捕获

    expect(pageDepth.value, 1, reason: '桌面点导航应先把全屏页退掉');
    expect(find.text('二级页正文'), findsNothing);
    expect(railSelectedIndex(tester), 3, reason: '退页之后仍要切到「我的」');
    expect(
      find.byType(NavigationRail),
      findsOneWidget,
      reason: '切 tab 后导航仍在场(桌面常驻)',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手机语义(debugForceNonDesktopPlatform): 推整页路由后 Rail 让位', (
    tester,
  ) async {
    debugForceNonDesktopPlatform = true;
    await pumpHome(tester, const Size(1000, 900));
    expect(find.byType(NavigationRail), findsOneWidget);

    await pushFullPage(tester, frames: 5);

    expect(pageDepth.value, 2);
    expect(
      find.byType(NavigationRail),
      findsNothing,
      reason: '手机全屏页仍要让导航让位(原语义不变)',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('播放条宽度口径: 取实测可用宽(窗口 - kRailWidth), 不取窗口宽', (tester) async {
    // 窗口 950 落在宽档(>= 900), 但宽档 Rail 占掉 80 后播放条实际只有 870 = 中档。
    // 用窗口宽会在 900~980 这区间错判档位(这里具体是误加专辑名)。
    tester.view.physicalSize = const Size(950, 240);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(width: kRailWidth),
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: MiniPlayerBar(
                    data: PlayerBarData(
                      player: PlayerView(
                        playing: true,
                        positionMs: BigInt.from(30000),
                        durationMs: BigInt.from(200000),
                        volume: 1.0,
                      ),
                      current: rust.SongDto(
                        id: BigInt.one,
                        name: '歌名甲',
                        artist: '艺人乙',
                        artistId: BigInt.one,
                        album: '专辑丙',
                        albumId: BigInt.one,
                        coverUrl: null,
                        durationMs: BigInt.from(200000),
                        fee: 0,
                        vip: false,
                        paid: false,
                        playable: true,
                      ),
                      liked: false,
                      queueIndex: 1,
                      queueLength: 2,
                      dragMax: null,
                      dragMs: null,
                    ),
                    actions: PlayerBarActions(
                      onSeekStart: (_) {},
                      onSeekChanging: (_) {},
                      onSeekEnd: (_) {},
                      onToggleLyrics: () {},
                      onOpenDetail: () {},
                      onToggleLike: () {},
                      onToggle: () {},
                      onPrevious: () {},
                      onNext: () {},
                      onCycleMode: () {},
                      onOpenQueue: () {},
                    ),
                    absorbBottomInset: false,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.getSize(find.byType(MiniPlayerBar)).width, 950 - kRailWidth);
    final barText = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byType(MiniPlayerBar),
            matching: find.byType(Text),
          ),
        )
        .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
        .join('\n');
    expect(
      barText,
      isNot(contains('专辑丙')),
      reason: '实际宽 870 = 中档, 用窗口宽 950 会误判成宽档并追加专辑名',
    );
    expect(tester.takeException(), isNull);
  });
}
