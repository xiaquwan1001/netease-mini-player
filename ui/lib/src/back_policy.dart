/// 根页面返回键优先级([HomeBackAction])与把它接到系统返回键上的小组件。
///
/// 从 `main.dart` 原样搬出, 行为不变: 只有"栈底且无二级态"才放行系统把 Android
/// 返回键/桌面 Esc 交给系统, 其余一律先退一层(审查 P0-7.1)。
library;

import 'package:flutter/material.dart';

/// 根页面的返回键优先级, 从高到低:
/// 歌词展开 → 收起歌词; 非首 tab → 回搜索 tab; 歌单浏览态 → 退出浏览;
/// 都没有(栈底 + 无二级态) → 交还系统, 由系统退出 App.
///
/// 纯函数, 便于单测(返回键的分支比 UI 更容易出错).
enum HomeBackAction { collapseLyrics, resetTab, closeLibrary, exitApp }

HomeBackAction resolveHomeBackAction({
  required bool showLyrics,
  required int tab,
  required bool libraryOpen,
}) {
  if (showLyrics) return HomeBackAction.collapseLyrics;
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
