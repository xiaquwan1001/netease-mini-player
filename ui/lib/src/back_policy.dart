/// 根页面返回键优先级([HomeBackAction])与把它接到系统返回键上的小组件。
///
/// 从 `main.dart` 原样搬出, 行为不变: 只有"栈底且无二级态"才放行系统把 Android
/// 返回键/桌面 Esc 交给系统, 其余一律先退一层(审查 P0-7.1)。
library;

import 'package:flutter/material.dart';

/// 根页面的返回键优先级, 从高到低:
/// 歌词展开 → 收起歌词; 主从分栏的右栏详情 → **只清右栏**(不 pop 页面);
/// 非首 tab → 回搜索 tab; 歌单浏览态 → 退出浏览; 搜索页有输入/结果 → 清搜索;
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

  /// 搜索页有输入/有结果: 先回到搜索落地页(清关键词与结果), **不要**直接退出 App。
  ///
  /// 2026-11-26 Android 交互审计: 以前没有这一级 —— 在搜索页提交过关键词(键盘已收起)
  /// 时按系统返回键, 判定落到 [exitApp], 整个 App 直接退出; 桌面 Esc 同理(只是表现为
  /// "没反应", 因为根路由是 bubble)。
  clearSearch,
  exitApp,
}

HomeBackAction resolveHomeBackAction({
  required bool showLyrics,
  required int tab,
  required bool libraryOpen,
  bool detailPaneOpen = false,
  bool searchActive = false,
}) {
  if (showLyrics) return HomeBackAction.collapseLyrics;
  if (detailPaneOpen) return HomeBackAction.closeDetailPane;
  if (tab != 0) return HomeBackAction.resetTab;
  if (libraryOpen) return HomeBackAction.closeLibrary;
  if (searchActive) return HomeBackAction.clearSearch;
  return HomeBackAction.exitApp;
}

/// 把 [HomeBackAction] 接到系统返回键(Android 手势/返回键, 桌面 Esc)上.
///
/// 只有"栈底且无二级态"时 canPop=true 让系统退出, 其余一律拦下来先退一层;
/// 否则用户在歌词页/推荐页按返回会直接退出 App(审查 P0-7.1).
class HomeBackGuard extends StatefulWidget {
  const HomeBackGuard({
    super.key,
    required this.action,
    required this.onBack,
    this.listenable,
    required this.child,
  });

  /// **现取**的优先级(不是快照): 判定依赖会变的状态(搜索框里的文本、搜索结果、
  /// 右栏), 而这些变化不一定经过页面 setState —— 传值的话 `canPop` 会停在旧值上。
  final HomeBackAction Function() action;

  final VoidCallback onBack;

  /// 会改变 [action] 结果的外部状态(文本控制器 / 搜索状态机)。
  ///
  /// 只用来让本组件重建一次 `PopScope`(child 是同一个 widget 实例, Flutter 不会
  /// 重建页面子树), 所以输入框每敲一个字都是零成本, 不会因此重排整页。
  final Listenable? listenable;

  final Widget child;

  @override
  State<HomeBackGuard> createState() => _HomeBackGuardState();
}

class _HomeBackGuardState extends State<HomeBackGuard> {
  @override
  void initState() {
    super.initState();
    widget.listenable?.addListener(_onStateChanged);
  }

  @override
  void didUpdateWidget(covariant HomeBackGuard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.listenable, widget.listenable)) {
      oldWidget.listenable?.removeListener(_onStateChanged);
      widget.listenable?.addListener(_onStateChanged);
    }
  }

  @override
  void dispose() {
    widget.listenable?.removeListener(_onStateChanged);
    super.dispose();
  }

  void _onStateChanged() {
    // 只重建 PopScope 这一层: widget.child 与上一帧是同一个实例
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: widget.action() == HomeBackAction.exitApp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        widget.onBack();
      },
      child: widget.child,
    );
  }
}
