// 宽档左侧导航栏(lane/ui-adaptive P3)的壳层回归。
//
// 口径(见 lib/src/layout.dart 的「布局档位」+ app_shell.dart 的 _PlayerBarChrome):
//   · 可用宽 >= 900 ⇒ HomePage 投递 NavigationRail, 壳层把它挂在**左侧**,
//     内容与播放条在右列;
//   · < 900 ⇒ 仍然只有底部 NavigationBar(窄/中档几何与改动前一致);
//   · 导航语义完全等价: 同一 selectedIndex / 同一回调 / 标签常显 / pageDepth 让位。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/layout.dart';

/// HomePage 的 bootstrap 会去打平台通道/Rust(测试里必然失败 → 进错误态)并起轮询
/// Timer, 所以只 pump 固定帧数, 退出时把树换掉停 Timer(同 ui_batch_a_back_nav_test)。
Future<void> pumpHome(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => playerBarSlot.value = null);
  await tester.pumpWidget(
    MaterialApp(
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

int? railSelectedIndex(WidgetTester tester) =>
    tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex;

void main() {
  testWidgets('宽档(1000x900): 出现左侧 NavigationRail, 没有底部 NavigationBar', (
    tester,
  ) async {
    await pumpHome(tester, const Size(1000, 900));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(
      find.byType(NavigationBar),
      findsNothing,
      reason: '宽档不允许底部导航与 Rail 同时在场',
    );

    final rail = tester.getRect(find.byType(NavigationRail));
    expect(rail.left, 0, reason: 'Rail 必须贴在左侧');
    expect(rail.width, kRailWidth, reason: 'Rail 宽度应等于 kRailWidth');

    // 内容区在 Rail 右侧, 且被限宽居中: 右列宽 = 1000 - 80 = 920 ⇒ 左边距 80 + 40
    final scaffold = tester.getRect(find.byType(Scaffold).first);
    expect(scaffold.width, kContentMaxWidth, reason: '宽档内容区应被限宽');
    expect(scaffold.left, kRailWidth + (920 - kContentMaxWidth) / 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('中档(840x800): 只有底部 NavigationBar, 内容铺满', (tester) async {
    await pumpHome(tester, const Size(840, 800));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    final scaffold = tester.getRect(find.byType(Scaffold).first);
    expect(scaffold.width, 840, reason: '中档(<限宽)内容不该被收窄');
    expect(scaffold.left, 0);
  });

  testWidgets('窄档(400x800): 只有底部 NavigationBar, 内容铺满', (tester) async {
    await pumpHome(tester, const Size(400, 800));
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    final scaffold = tester.getRect(find.byType(Scaffold).first);
    expect(scaffold.width, 400);
    expect(scaffold.left, 0);
  });

  testWidgets('点 Rail 项切 tab: 选中态跟着变, 且不弹底部导航', (tester) async {
    await pumpHome(tester, const Size(1000, 900));
    // 冷启动默认落在「推荐」(与底部导航同一启动口径)
    expect(railSelectedIndex(tester), 1);

    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('我的'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));

    expect(railSelectedIndex(tester), 3, reason: '点 Rail 的「我的」应切到第 4 个 tab');
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(AppBar), findsNothing, reason: '五个 tab 首页都不该有顶部栏');

    // 切回首 tab 也正常(回调与 NavigationBar 同一份)
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationRail),
        matching: find.text('搜索'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 32));
    expect(railSelectedIndex(tester), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽档 + 矮窗口(1000x420): Rail 自己滚, 不竖溢', (tester) async {
    await pumpHome(tester, const Size(1000, 420));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '矮窗口下 Rail 不该 RenderFlex overflow',
    );
  });
}
