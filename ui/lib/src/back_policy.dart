/// 根页面返回键优先级([HomeBackAction])与把它接到系统返回键上的小组件。
///
/// 从 `main.dart` 原样搬出, 行为不变: 只有"栈底且无二级态"才放行系统把 Android
/// 返回键/桌面 Esc 交给系统, 其余一律先退一层(审查 P0-7.1)。
library;

import 'package:flutter/material.dart';

/// 根页面的返回键优先级, 从高到低:
/// 歌词展开 → 收起歌词; 主从分栏的右栏详情 → **只清右栏**(不 pop 页面);
/// 非首 tab → 回搜索 tab; 歌单浏览态 → 退出浏览;
/// 都没有(栈底 + 无二级态) → 交还系统, 由系统退出 App.
///
/// 纯函数, 便于单测(返回键的分支比 UI 更容易出错).
///
/// **两条不同的返回语义要分清**(方案 B · S4 的设计选择, 不是 bug):
///   · 宽档(主从分栏): 右栏是"同一页的第二列" ⇒ 返回只清右栏, 页面与左栏都不动,
///     再按一次才轮到 [resetTab] / 退出;
///   · 窄/中档: 详情是 push 出来的一整页 ⇒ 系统返回键 pop 掉它(那时根本轮不到这个
///     纯函数, detailPaneOpen 恒为 false)。
/// 所以 [HomeBackAction.closeDetailPane] 必须排在 [resetTab] **之前**:
/// 右栏还开着就跳 tab, 用户会看到"详情凭空消失又换了个 tab"。
enum HomeBackAction {
  collapseLyrics,
  closeDetailPane,
  resetTab,
  closeLibrary,
  exitApp,
}

HomeBackAction resolveHomeBackAction({
  required bool showLyrics,
  required int tab,
  required bool libraryOpen,
  bool detailPaneOpen = false,
}) {
  if (showLyrics) return HomeBackAction.collapseLyrics;
  if (detailPaneOpen) return HomeBackAction.closeDetailPane;
  if (tab != 0) return HomeBackAction.resetTab;
  if (libraryOpen) return HomeBackAction.closeLibrary;
  return HomeBackAction.exitApp;
}

/// 把 [HomeBackAction] 接到系统返回键(Android 手势/返回键, 桌面 Esc)上.
///
/// 只有"栈底且无二级态"时 canPop=true 让系统退出, 其余一律拦下来先退一层;
/// 否则用户在歌词页/推荐页按返回会直接退出 App(审查 P0-7.1).
class HomeBackGuard extends StatelessWidget {
  const HomeBackGuard({
    super.key,
    required this.action,
    required this.onBack,
    required this.child,
  });

  final HomeBackAction action;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: action == HomeBackAction.exitApp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        onBack();
      },
      child: child,
    );
  }
}
