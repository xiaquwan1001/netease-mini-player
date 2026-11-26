import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';

import 'support/nav_chrome.dart';

/// 横屏矮窗口(中档: 底部导航, 宽 800)。
const Size kLandscapeShort = Size(800, 400);

/// 横屏刘海/挖孔: 首页正文以前只吃 `top` 安全区, 横屏挖孔在左/右时会把搜索框与列表
/// 压到屏边下面(2026-11-26 Linux/Android 交互审查)。
///
/// 口径: 首页 body 最外层保留"没有 AppBar 才吃 top"的旧规则, 同时**一律**吃
/// `left/right`。这里直接 pump 生产的 `HomePage`(不是复制一份 padding 规则) ——
/// 断言的是真实几何, 规则改了测试会红, 不会出现"测试与实现各写一份"的假绿。
Future<void> pumpHomeWithInsets(WidgetTester tester, EdgeInsets padding) async {
  tester.view.physicalSize = kLandscapeShort;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => playerBarSlot.value = null);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQueryData(
          size: kLandscapeShort,
          padding: padding,
          viewPadding: padding,
          textScaler: TextScaler.noScaling,
        ),
        // 导航本体由根布局的 PlayerBarHost 渲染(与生产同一条壳)
        child: PlayerBarHost(content: child ?? const SizedBox.shrink()),
      ),
      home: const HomePage(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  // 首页冷启动落在「推荐」tab, 那里没有搜索框 —— 切到搜索 tab 才量得到几何。
  // 800x400 是中档(底部 NavigationBar); 用档位中立的 navChromeFinder 找「搜索」。
  await tester.tap(
    find.descendant(of: navChromeFinder, matching: find.text('搜索')),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 32));
  addTearDown(() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } catch (_) {}
  });
}

void main() {
  testWidgets('横屏左侧挖孔(left=40): 搜索框不压到挖孔下面', (tester) async {
    await pumpHomeWithInsets(tester, const EdgeInsets.only(left: 40));

    final field = tester.getRect(find.byType(TextField).first);
    expect(
      field.left,
      greaterThanOrEqualTo(40),
      reason: '搜索框被左侧刘海/挖孔压住了(正文只吃了 top 安全区)',
    );
  });

  testWidgets('横屏右侧挖孔(right=40): 搜索框右边界让出安全区', (tester) async {
    await pumpHomeWithInsets(tester, const EdgeInsets.only(right: 40));

    final field = tester.getRect(find.byType(TextField).first);
    expect(
      field.right,
      lessThanOrEqualTo(kLandscapeShort.width - 40),
      reason: '右侧挖孔区不许压内容',
    );
  });

  testWidgets('无挖孔: 几何不变(不吃 padding 时左边界仍只有页面自身留白)', (tester) async {
    await pumpHomeWithInsets(tester, EdgeInsets.zero);

    final field = tester.getRect(find.byType(TextField).first);
    expect(field.left, greaterThan(0));
    expect(field.left, lessThan(40));
  });
}
