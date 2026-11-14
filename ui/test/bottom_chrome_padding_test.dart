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

  /// 回归 2026-11-14 用户反馈 4/6: 键盘一弹出, 联想面板与键盘之间就有一段
  /// 高度随输入法出现的空缺。根因是 Scaffold 已经按 viewInsets.bottom 收缩过,
  /// 而根布局里的底部导航栏仍然占着 80dp ⇒ 内容底边 = 键盘顶 - 80dp。
  testWidgets('键盘弹出时底部导航让位, 不再留一条导航栏高的空缺', (tester) async {
    const keyboard = 300.0;
    playerBarSlot.value = navBar();
    Widget shell(EdgeInsets insets) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(
          size: const Size(400, 800),
          padding: const EdgeInsets.only(top: statusBar, bottom: gestureInset),
          viewPadding: const EdgeInsets.only(
            top: statusBar,
            bottom: gestureInset,
          ),
          viewInsets: insets,
        ),
        child: PlayerBarHost(content: child ?? const SizedBox.shrink()),
      ),
      home: const Scaffold(body: Center(child: Text('body'))),
    );

    await tester.pumpWidget(shell(EdgeInsets.zero));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pumpWidget(shell(const EdgeInsets.only(bottom: keyboard)));
    await tester.pumpAndSettle();
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: '键盘在场时导航栏必须让位, 否则内容区底部会空出一条导航栏高的缺口',
    );
    // 播放条同样让位(键盘挡住它, 留着只会白占高度)
    expect(find.byType(MiniPlayerBar), findsNothing);
  });
}
