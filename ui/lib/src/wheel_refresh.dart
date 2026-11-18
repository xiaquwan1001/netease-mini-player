import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 桌面(鼠标/触控板)**下拉刷新**的补入口: 列表已在顶部时继续向上滚轮,
/// 触发一次 [onRefresh]。
///
/// 为什么需要: 手指下拉走的是 RefreshIndicator(移动端); 桌面既没有"手指",
/// 默认的 [ScrollBehavior] 也不让鼠标拖动列表(见 `AppScrollBehavior`),
/// 于是 Linux/Windows 桌面完全没有刷新入口。用户 2026-11-18: "Linux 桌面没有
/// 下拉刷新触发逻辑, 要补: 拖拽下拉或滚轮滑动能触发刷新"。这里补滚轮这一半:
///
///   · 拖拽: 应用级 ScrollBehavior 放开 mouse/trackpad/stylus 的 dragDevices,
///     RefreshIndicator 的 overscroll 判定因此照常生效(不改本组件的逻辑);
///   · 滚轮: 本组件监听 PointerScrollEvent —— 只有"已在顶部 + 继续向上滚"才触发,
///     所以普通上滑(列表还能滚)不会被误判成刷新。
///
/// "是否在顶部"取自滚动通知的 [ScrollMetrics.extentBefore](滚动位置的实测值),
/// 不是猜方向; 触发后进入 [debounce] 冷却(滚轮一秒能来几十个事件),
/// 且在 [onRefresh] 未完成前不重复触发。
class WheelRefreshable extends StatefulWidget {
  const WheelRefreshable({
    super.key,
    required this.onRefresh,
    required this.child,
    this.debounce = const Duration(milliseconds: 1500),
  });

  /// 与 RefreshIndicator.onRefresh 同义: 刷新一次, 完成时 Future 结束
  final Future<void> Function() onRefresh;
  final Widget child;

  /// 触发冷却期(期间重复滚轮只算一次)
  final Duration debounce;

  @override
  State<WheelRefreshable> createState() => _WheelRefreshableState();
}

class _WheelRefreshableState extends State<WheelRefreshable> {
  /// 最近一次滚动通知给出的"是否已在顶部"(初始按"在顶部"算: 首帧还没滚动过)
  bool _atTop = true;

  /// 刷新请求在途
  bool _busy = false;

  /// 冷却计时器: 非 null = 冷却中
  Timer? _cooldown;

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    final metrics = notification.metrics;
    if (metrics.axis == Axis.vertical) {
      _atTop = metrics.extentBefore <= 0.0;
    }
    // 只观察, 不拦截(横向艺人条 / 内层横滑列表照常工作)
    return false;
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    // dy < 0 = 向上滚(想回到更早的内容): 在顶部就是"再拉一下"的桌面版
    if (event.scrollDelta.dy >= 0) return;
    if (!_atTop || _busy || _cooldown != null) return;
    _cooldown = Timer(widget.debounce, () => _cooldown = null);
    _trigger();
  }

  Future<void> _trigger() async {
    _busy = true;
    try {
      await widget.onRefresh();
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: _onPointerSignal,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      ),
    );
  }
}
