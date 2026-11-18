// 浮层的**唯一入口**(U-03, 2026-11-18)。
//
// 规则(硬): 新代码一律走 `showAppSheet` / `showAppDialog`;
// 在业务代码里**直接**调 `showModalBottomSheet` / `showDialog` / `showGeneralDialog`
// 视为**回归** —— `tools/check-sheet-entry.sh` 会红灯(白名单只有本文件、
// `popup_routes.dart` 与 `ui/test/**`)。
//
// 为什么收口(两件事, 以前各做各的):
//  1. **能被收掉**: 切底部 tab 时要按 route 逐条收起浮层(U-01/U-02, 见
//     `app_shell.dart` 的 `dismissAllPopups()`)。底部面板只有自己造
//     `ModalBottomSheetRoute`(`popup_routes.dart` 的 `buildAppSheetRoute`)才拿得到
//     route, 所以 `showAppSheet` 走它; 参数口径与 `showModalBottomSheet` 完全一致
//     (主题捕获 / 遮罩文案 / 遮罩色 / 可点遮罩关闭 / 可拖动)。对话框走 `showDialog`,
//     它本来就是 `DialogRoute`(PopupRoute), 同样进登记表。
//  2. **默认值不漂**: 全仓 20 处 sheet 调用里 `isScrollControlled: true` 13 处、
//     `showDragHandle: true` 19 处(2026-11-18 实测, 见
//     `.pi/plans/q2-app-sheet-2026-11-18.md`), 少数派以前靠"漏写"表达,
//     读代码看不出是默认还是忘了。这里把多数派做成默认, 少数派**显式写出来**。
//
// 高度口径: 面板高度一直是 builder 内部的事(`SizedBox(height: 屏高 * 0.6~0.8)`),
// 没有调用点用过路由级高度。[showAppSheet] 的 `initialHeight` 只给**新代码**用,
// 已迁移的调用点保持各自原来的包裹, 尺寸零变化。
import 'package:flutter/material.dart';

import 'popup_routes.dart' show buildAppSheetRoute;

/// 打开底部面板: 本仓**唯一**的 sheet 入口。
///
/// 返回面板关闭时的结果(与 `showModalBottomSheet` 同口径: `null` = 用户取消/
/// 点遮罩/下滑关掉)。泛型 [T] 必须与 builder 里 `Navigator.pop(ctx, value)` 的
/// 实参类型一致, 否则调用点拿到的永远是 `null`。
///
/// - [isScrollControlled]: 默认 true(多数派): 面板可超过半屏、可用键盘避让。
///   内容只有几行小列表、且希望最高只到 9/16 屏时显式传 false。
/// - [showDragHandle]: 默认 true(多数派): 顶部拖拽条。
/// - [useSafeArea]: 默认 false, 与 `showModalBottomSheet` 默认一致; 需要避让刘海/
///   手势条时再开, 或按既有做法在 builder 里自己包 `SafeArea`。
/// - [initialHeight]: 屏高比例(0, 1] —— 随便给一个高度;**已迁移的老调用点不用它**
///   (它们各自在 builder 里定高, 换成它等于改尺寸)。
/// - [settings]: 路由 settings(埋点/测试按名字定位时用)。
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool isScrollControlled = true,
  bool showDragHandle = true,
  bool useSafeArea = false,
  double? initialHeight,
  RouteSettings? settings,
}) {
  assert(
    initialHeight == null || (initialHeight > 0 && initialHeight <= 1),
    'initialHeight 是屏高比例(0, 1], 不是像素',
  );
  return Navigator.of(context).push<T>(
    buildAppSheetRoute<T>(
      context: context,
      builder: initialHeight == null
          ? builder
          : (sheetContext) => SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * initialHeight,
              child: builder(sheetContext),
            ),
      settings: settings,
      isScrollControlled: isScrollControlled,
      showDragHandle: showDragHandle,
      useSafeArea: useSafeArea,
    ),
  );
}

/// 打开对话框: 本仓**唯一**的 dialog 入口。
///
/// 参数默认值与 [showDialog] 逐字相同([barrierDismissible] true / [useSafeArea] true),
/// 所以从 `showDialog` 迁过来只需换函数名。返回 `Dialog` 里 `Navigator.pop(ctx, v)`
/// 的 v(用户点遮罩关掉时是 `null`)。
///
/// 为什么不自己也造 route: `showDialog` 已经给出 `DialogRoute`(PopupRoute),
/// 收口的意义在于"调用点只有一处可写", 而不是再造一条路由。
Future<T?> showAppDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool barrierDismissible = true,
  Color? barrierColor,
  bool useSafeArea = true,
  RouteSettings? settings,
}) {
  return showDialog<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    barrierColor: barrierColor,
    useSafeArea: useSafeArea,
    routeSettings: settings,
  );
}
