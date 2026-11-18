import 'package:flutter/material.dart';

// 浮层(sheet/dialog)的两把公共扳手。
//
// **不是**统一入口: 统一入口是 `app_sheet.dart` 的 `showAppSheet` / `showAppDialog`
// (U-03, 2026-11-18; 它内部就用 `buildAppSheetRoute`)。这里只解决「谁是我这一条 route」
// —— 给需要自己持有 route 的两处(登录弹层 / 播放队列面板)造路由, 以及
// 「关掉我这一条」的通用动作(登录弹层 / 队列面板 / 切 tab 收起全部浮层共用一份)。

/// 造一条与 `showModalBottomSheet` 同口径的底部面板路由(主题捕获 / 遮罩文案 / 拖拽条)。
///
/// 为什么不直接用 `showModalBottomSheet`: 它不把 route 交出来, 调用方于是拿不到
/// 「我自己那一条」, 想关自己只能 `Navigator.maybePop()` —— 一旦面板之上又压了别的
/// 浮层(队列面板上的「清空确认框」), pop 掉的是上层, 面板还开着(U-02)。
ModalBottomSheetRoute<T> buildAppSheetRoute<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool isScrollControlled = true,
  bool showDragHandle = true,
  bool useSafeArea = false,
}) {
  final navigator = Navigator.of(context);
  final l10n = MaterialLocalizations.of(context);
  return ModalBottomSheetRoute<T>(
    settings: settings,
    builder: builder,
    // 与 showModalBottomSheet 一致: 把调用点的 Inherited 主题搬进面板
    capturedThemes: InheritedTheme.capture(
      from: context,
      to: navigator.context,
    ),
    isScrollControlled: isScrollControlled,
    showDragHandle: showDragHandle,
    // 与 showModalBottomSheet 的默认一致(false); 全仓没有调用点开过它
    useSafeArea: useSafeArea,
    barrierLabel: l10n.scrimLabel,
    barrierOnTapHint: l10n.scrimOnTapHint(l10n.bottomSheetLabel),
    modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
  );
}

/// 关掉**这一条**浮层路由: 不碰压在它上面的, 也不碰下面的。
///
/// - [Route.isCurrent] 为真 ⇒ `pop()`(走正常收起动画);
/// - 否则(上面还压着别的浮层) ⇒ `removeRoute()`, 只摘自己。
///
/// 返回是否真的关掉了(route 为 null / 已不活跃时为 false)。
bool dismissPopupRoute(Route<dynamic>? route) {
  if (route == null || !route.isActive) return false;
  final navigator = route.navigator;
  if (navigator == null) return false;
  if (route.isCurrent) {
    navigator.pop();
  } else {
    navigator.removeRoute(route);
  }
  return true;
}
