// 壳层导航(底部 NavigationBar / 左侧 NavigationRail)的通用查找器。
//
// 为什么需要: 2026-11 起「宽屏怎么排」由壳层按**可用宽度**决定(lane/ui-adaptive P3),
// 宽档(>= 900)投递 NavigationRail、中/窄档仍然是 NavigationBar。断言「导航里有某个
// tab」的测试不该因此各写一套分支 —— 用这里的 navChromeFinder 找"导航本体",
// 用 navSelectedIndex 读选中态, 两个档位同一份断言。
//
// 需要**分档断言**的用例(如 nav_rail_shell_test)请直接 find.byType(NavigationRail),
// 不要用这里的中性查找器, 否则测不出"该出现的没出现"。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 导航本体: 底部 NavigationBar 或左侧 NavigationRail(同一时刻只有一个)。
final Finder navChromeFinder = find.byWidgetPredicate(
  (widget) => widget is NavigationBar || widget is NavigationRail,
  description: 'NavigationBar 或 NavigationRail',
);

/// 当前选中的 tab 序号(与两个组件各自的 selectedIndex 口径一致)。
int? navSelectedIndex(WidgetTester tester) {
  final bars = tester.widgetList<NavigationBar>(find.byType(NavigationBar));
  if (bars.isNotEmpty) return bars.first.selectedIndex;
  final rails = tester.widgetList<NavigationRail>(find.byType(NavigationRail));
  if (rails.isNotEmpty) return rails.first.selectedIndex;
  return null;
}
