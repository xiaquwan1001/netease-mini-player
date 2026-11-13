import 'package:flutter/material.dart';

import 'error_views.dart' show InlineError;
import 'net_retry.dart';
import 'state_views.dart';

/// 异步四态容器: 加载中 / 出错 / 空 / 有数据.
///
/// 为什么收敛: 收敛前「我的」页与「推荐」页各自写了一份私有的 `_AsyncSection`
/// (`mine_view.dart` 带 keepAlive, `recommend_view.dart` 自带一份 `_InlineError`),
/// 排行榜/榜单/ MV 页又各手写一遍 `FutureBuilder` 的四态判定, 同一件事有 5 份实现,
/// 空态/错误态口径随时会漂。这里收敛成唯一实现:
/// - 取数统一走 [retryNetwork](网络错误自动退避重试, 鉴权/风控错误立刻抛出);
/// - 出错统一用 [InlineError](文案走 [friendlyError], 右侧「重试」重新取数);
/// - 空态统一是 [Padding] + `bodySmall` 文案, 允许调用方用 [emptyBuilder] 换视觉;
/// - [keepAlive] 给 ListView 里的区块用(移出视野不被回收, 回来不重新转圈)。
///
/// 判定口径与迁移前的两份 `_AsyncSection` 逐字一致: 未完成为加载中,
/// `hasError` 为错误, `data == null` / 空 List / 空串为空态。
class AsyncView<T> extends StatefulWidget {
  const AsyncView({
    super.key,
    this.load,
    this.future,
    required this.builder,
    required this.emptyText,
    this.emptyBuilder,
    this.keepAlive = false,
    this.loadingPadding = const EdgeInsets.symmetric(vertical: 20),
    this.loadingSize = 22,
    this.loadingBuilder,
    this.errorBuilder,
    this.onRetry,
  }) : assert(load != null || future != null, 'load 与 future 至少给一个');

  /// 取数(不含重试, 重试由本组件套 [retryNetwork]).
  final Future<T> Function()? load;

  /// 由**父层持有**的 future(与 [load] 二选一)。
  ///
  /// 给「下拉刷新时不让内容闪回加载态」的页面用(风格详情页): 父层把新数据包成
  /// `Future.value(...)` 传下来, 本组件换 future 而不重挂载, 已渲染的内容不消失。
  final Future<T>? future;

  /// 有数据时的内容; [reload] 是「重试/刷新这一块」的回调.
  final Widget Function(BuildContext context, T data, VoidCallback reload)
  builder;

  /// 空态文案(T 是空 List / 空串 / null 时显示).
  final String emptyText;

  /// 自定义空态(优先级高于 [emptyText]).
  final WidgetBuilder? emptyBuilder;

  /// true 时混入 [AutomaticKeepAliveClientMixin]:
  /// 区块移出视野被回收后回来不重新转圈(列表页上下抽搐的原因)。
  final bool keepAlive;

  /// 加载中指示器的留白(交给 [LoadingView]).
  final EdgeInsetsGeometry loadingPadding;

  /// 加载中指示器边长(交给 [LoadingView]).
  final double loadingSize;

  /// 整块自定义加载态(如整页居中的 [LoadingView]), 优先级高于 loadingPadding/Size.
  final WidgetBuilder? loadingBuilder;

  /// 整块自定义错误态(如整页居中的 FullError); 不传则用行内 [InlineError].
  final Widget Function(BuildContext context, Object error, VoidCallback retry)?
  errorBuilder;

  /// 重试回调(不传则自己重新取 [load]; 用 [future] 时由调用方提供).
  final VoidCallback? onRetry;

  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>>
    with AutomaticKeepAliveClientMixin<AsyncView<T>> {
  late Future<T> _future;

  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  void initState() {
    super.initState();
    _future = _start();
  }

  @override
  void didUpdateWidget(covariant AsyncView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父层换了 future(下拉刷新把新数据包成 Future.value) ⇒ 换掉本地 future,
    // 但不重挂载: 旧内容不闪回加载态。注意不能比 load 的函数身份 —— 调用点
    // 每次 build 都会新建闭包, 比身份会变成"每帧重取"。
    if (widget.future != null && !identical(widget.future, oldWidget.future)) {
      _future = _start();
    }
  }

  Future<T> _start() {
    final pending = widget.future;
    if (pending != null) return pending;
    return retryNetwork(widget.load!);
  }

  /// 重试: 换一个 future 重新走四态(不换 key 也能刷新本块)。
  /// 注意用块体: 箭头体会把 Future 变成 setState 回调的返回值, Flutter 会断言失败。
  void _reload() {
    final handler = widget.onRetry;
    if (handler != null) {
      handler();
      return;
    }
    final load = widget.load;
    if (load == null) return;
    setState(() {
      _future = retryNetwork(load);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          final loadingBuilder = widget.loadingBuilder;
          if (loadingBuilder != null) return loadingBuilder(context);
          return LoadingView(
            size: widget.loadingSize,
            padding: widget.loadingPadding,
          );
        }
        if (snap.hasError) {
          final errorBuilder = widget.errorBuilder;
          if (errorBuilder != null) {
            return errorBuilder(context, snap.error!, _reload);
          }
          return InlineError(
            message: friendlyError(snap.error!),
            onRetry: _reload,
          );
        }
        final data = snap.data;
        if (data == null ||
            (data is List && data.isEmpty) ||
            (data is String && data.isEmpty)) {
          final emptyBuilder = widget.emptyBuilder;
          if (emptyBuilder != null) return emptyBuilder(context);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              widget.emptyText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        return widget.builder(context, data as T, _reload);
      },
    );
  }
}
