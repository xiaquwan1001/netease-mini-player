import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/playback.dart';

/// 回归: 底部条(播放条 + 首页导航栏)挂在根布局(Navigator 之外), 看到的是根 MediaQuery,
/// 其中 padding.top 仍是状态栏高度。两个子组件内部都有 SafeArea:
/// - MiniPlayerBar 自己写了 `top: false`;
/// - NavigationBar 内部的 SafeArea 没关 top, 由 _PlayerBarChrome 用
///   MediaQuery.removePadding(removeTop: true) 剥掉。
/// 不这么做的话, 底栏会各自多吃一条状态栏高的空白(实测 44dp × 2),
/// 表现为"播放条与底部导航之间有一段空 + 页面内容被挤上来"(2026-11-12 用户报)。
void main() {
  const statusBar = 44.0;
  const gestureInset = 24.0;
  const navContentHeight = 80.0; // Material 3 NavigationBar 默认高

  setUp(() {
    playerBarActions.value = PlayerBarActions(
      onSeekStart: (_) {},
      onSeekChanging: (_) {},
      onSeekEnd: (_) {},
      onToggleLyrics: () {},
      onOpenDetail: () {},
      onToggleLike: () {},
      onCycleMode: () {},
      onOpenQueue: () {},
      onToggle: () {},
      onPrevious: () {},
      onNext: () {},
    );
    playerBarData.value = PlayerBarData(
      player: PlayerView(
        playing: true,
        positionMs: BigInt.from(30000),
        durationMs: BigInt.from(200000),
        volume: 1.0,
      ),
      current: null,
      liked: false,
      queueIndex: 1,
      queueLength: 1,
      dragMax: null,
      dragMs: null,
    );
  });

  tearDown(() {
    playerBarSlot.value = null;
    playerBarData.value = null;
    playerBarActions.value = null;
  });

  Future<void> pumpShell(WidgetTester tester, {Widget? navBar}) async {
    playerBarSlot.value = navBar;
    const padding = EdgeInsets.only(top: statusBar, bottom: gestureInset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(
            size: Size(400, 800),
            padding: padding,
            viewPadding: padding,
          ),
          child: PlayerBarHost(content: child ?? const SizedBox.shrink()),
        ),
        home: const Scaffold(body: Center(child: Text('body'))),
      ),
    );
    await tester.pumpAndSettle();
  }

  Widget navBar() => NavigationBar(
    selectedIndex: 0,
    onDestinationSelected: (_) {},
    destinations: const [
      NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
      NavigationDestination(icon: Icon(Icons.person), label: '我的'),
    ],
  );

  testWidgets('有底部导航: 导航栏不吃状态栏 inset, 且与播放条零缝隙', (tester) async {
    await pumpShell(tester, navBar: navBar());

    final bar = tester.getRect(find.byType(MiniPlayerBar));
    final nav = tester.getRect(find.byType(NavigationBar));
    final slider = tester.getRect(find.byType(Slider));

    // 导航栏 = 内容 80 + 手势区安全边距(现在夹到 8dp, 用户要求整体下移、
    // 收掉底部多余空白; 状态栏 inset 仍然为 0)
    expect(
      nav.height,
      navContentHeight + 8,
      reason: '导航栏高度被状态栏 inset 撑大了, 或底部手势区没有按 8dp 夹住',
    );
    expect(nav.top - bar.bottom, 0, reason: '播放条与导航栏之间不允许有空隙');
    // 播放条顶部第一块内容(Slider)必须紧贴播放条顶部, 不允许状态栏空白
    expect(
      slider.top - bar.top,
      lessThan(1),
      reason: '播放条顶部多出空白带(状态栏 inset 被吃了两次)',
    );
    // 播放条自身高度只由内容决定(Slider 48 + 信息行 + 8 安全边距)
    expect(bar.height, lessThan(120), reason: '播放条被撑高了, 会挤压页面内容');
  });

  testWidgets('无底部导航(二级页): 播放条自己吃掉手势区, 但仍不吃状态栏', (tester) async {
    await pumpShell(tester, navBar: navBar());
    final withNav = tester.getRect(find.byType(MiniPlayerBar)).height;

    await pumpShell(tester, navBar: null);
    final withoutNav = tester.getRect(find.byType(MiniPlayerBar)).height;

    final bar = tester.getRect(find.byType(MiniPlayerBar));
    final slider = tester.getRect(find.byType(Slider));
    expect(slider.top - bar.top, lessThan(1), reason: '播放条顶部多出空白带');
    // 没有导航栏时播放条自己吃掉手势区 ⇒ 只比有导航时高出手势区那一条
    expect(withoutNav - withNav, gestureInset, reason: '无导航时播放条的底部手势区安全边距不对');
  });
}
