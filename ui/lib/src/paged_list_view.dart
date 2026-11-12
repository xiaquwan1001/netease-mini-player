import 'package:flutter/material.dart';

import 'net_retry.dart';
import 'toast.dart' show showToast;

/// 一页分页结果。
///
/// [hasMore] 由调用方判定(常见: `items.length >= pageSize`, 或服务端给了
/// 到底标志)。[nextCursor] 可选: 默认下一页 cursor = 本页 cursor + 去重后
/// 条数; 若调用方按"服务端已消费行数"翻页(有去重时与列表长度不一致),
/// 显式给出即可。
class PagedPage<T> {
  const PagedPage(this.items, {required this.hasMore, this.nextCursor});

  final List<T> items;
  final bool hasMore;
  final int? nextCursor;
}

/// loader(cursor) 闭包: cursor 从 0 开始, 由 [PagedListView] 维护并透传。
/// 组件不绑定任何 provider/FFI, 重试(retryNetwork)与数据获取都留给调用方。
typedef PagedLoader<T> = Future<PagedPage<T>> Function(int cursor);

/// 条目构建器: 同时给出当前已加载的全量条目, 供"点一首播整批"类交互使用。
typedef PagedItemBuilder<T> = Widget Function(
  BuildContext context,
  T item,
  int index,
  List<T> items,
);

/// 「分页 + 空态 + 错误重试」三件套公共列表。
///
/// 覆盖: 首屏加载 / 首屏错误(整页错误视图 + 重试) / 空态(文案或自定义视图)
/// / 下拉刷新 / 触底自动加载下一页(底部按钮兜底) / 加载更多失败
/// (保留旧数据 + SnackBar) / 按 [keyOf] 去重。
/// 错误文案统一走 [friendlyError]。
///
/// 传 [gridDelegate] 时按网格(SliverGrid)排版, 否则线性列表。
class PagedListView<T> extends StatefulWidget {
  const PagedListView({
    super.key,
    required this.loader,
    required this.itemBuilder,
    this.pageSize = 30,
    this.keyOf,
    this.emptyText = '暂无内容',
    this.emptyBuilder,
    this.header,
    this.separator,
    this.padding,
    this.gridDelegate,
    this.refreshable = true,
    this.endText,
    this.moreText = '加载更多',
    this.retryText = '重试',
    this.physics,
  });

  final PagedLoader<T> loader;
  final PagedItemBuilder<T> itemBuilder;

  /// 约定值: "返回条数 >= pageSize 视为还有下一页"; 组件自己不截断数据,
  /// 是否分页完全由 loader 闭包决定(单次加载的页面 hasMore 恒为 false)。
  final int pageSize;

  /// 去重键(同 key 不重复入列); null 表示不去重。
  final Object? Function(T item)? keyOf;

  final String emptyText;
  final Widget Function(BuildContext context, List<T> items)? emptyBuilder;

  /// 列表头(如筛选条、最近联系人横滑条), 随列表一起滚动。
  final Widget? header;

  /// 条目之间的分隔(如 Divider); 仅线性列表模式生效。
  final Widget? separator;

  final EdgeInsetsGeometry? padding;

  /// 传入则用网格排版(网格模式不支持 [separator])。
  final SliverGridDelegate? gridDelegate;

  final bool refreshable;

  /// 到底提示文案; null 则到底后不显示尾部件。
  final String? endText;
  final String moreText;
  final String retryText;
  final ScrollPhysics? physics;

  @override
  State<PagedListView<T>> createState() => _PagedListViewState<T>();
}

class _PagedListViewState<T> extends State<PagedListView<T>> {
  static const _prefetchDistance = 300.0;

  final List<T> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _cursor = 0;
  String? _error;

  /// 代际: 下拉刷新会 ++, 让仍在飞行的旧页/旧 _loadMore 结果直接丢弃
  /// (否则刷新后旧 cursor 的下一页会拼进新列表)。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final gen = ++_generation;
    setState(() {
      _loading = true;
      _loadingMore = false;
      _error = null;
      _cursor = 0;
      _items.clear();
    });
    try {
      final page = await widget.loader(0);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(_dedupe(page.items, <Object?>{}));
        _hasMore = page.hasMore;
        _cursor = page.nextCursor ?? page.items.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  Iterable<T> _dedupe(Iterable<T> page, Set<Object?> known) sync* {
    final keyOf = widget.keyOf;
    for (final item in page) {
      if (keyOf == null) {
        yield item;
        continue;
      }
      final key = keyOf(item);
      if (known.contains(key)) continue;
      known.add(key);
      yield item;
    }
  }

  Set<Object?> get _knownKeys => {
    if (widget.keyOf != null)
      for (final item in _items) widget.keyOf!(item),
  };

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore) return;
    final gen = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await widget.loader(_cursor);
      if (!mounted || gen != _generation) return;
      setState(() {
        _items.addAll(_dedupe(page.items, _knownKeys));
        _hasMore = page.hasMore;
        _cursor = page.nextCursor ?? (_cursor + page.items.length);
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || gen != _generation) return;
      setState(() => _loadingMore = false);
      // 加载更多失败: 保留旧数据, 只弹统一 toast 提示
      showToast(context, friendlyError(e), isError: true);
    }
  }

  bool _onScrollNotification(ScrollNotification n) {
    // 触底前 300px 自动预取; 短列表不产生滚动通知, 靠底部按钮兜底。
    if (n.metrics.pixels >= n.metrics.maxScrollExtent - _prefetchDistance) {
      _loadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _reload,
                child: Text(widget.retryText),
              ),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      final builder = widget.emptyBuilder;
      if (builder != null) return builder(context, _items);
      return Center(child: Text(widget.emptyText));
    }

    Widget body;
    if (widget.gridDelegate != null) {
      body = CustomScrollView(
        physics: widget.physics,
        slivers: [
          if (widget.header != null) SliverToBoxAdapter(child: widget.header!),
          SliverPadding(
            padding: widget.padding ?? EdgeInsets.zero,
            sliver: SliverGrid.builder(
              gridDelegate: widget.gridDelegate!,
              itemCount: _items.length,
              itemBuilder: (context, i) =>
                  widget.itemBuilder(context, _items[i], i, _items),
            ),
          ),
          SliverToBoxAdapter(child: _buildFooter(context)),
        ],
      );
    } else {
      final headerCount = widget.header == null ? 0 : 1;
      final separator = widget.separator;
      if (separator != null) {
        body = ListView.separated(
          physics: widget.physics,
          padding: widget.padding,
          itemCount: headerCount + _items.length + 1,
          separatorBuilder: (_, _) => separator,
          itemBuilder: (context, i) => _buildRow(context, i, headerCount),
        );
      } else {
        body = ListView.builder(
          physics: widget.physics,
          padding: widget.padding,
          itemCount: headerCount + _items.length + 1,
          itemBuilder: (context, i) => _buildRow(context, i, headerCount),
        );
      }
    }

    body = NotificationListener<ScrollNotification>(
      onNotification: _onScrollNotification,
      child: body,
    );
    if (!widget.refreshable) return body;
    return RefreshIndicator(onRefresh: _reload, child: body);
  }

  Widget _buildRow(BuildContext context, int i, int headerCount) {
    if (i < headerCount) return widget.header!;
    final index = i - headerCount;
    if (index < _items.length) {
      return widget.itemBuilder(context, _items[index], index, _items);
    }
    return _buildFooter(context);
  }

  /// 列表尾部: 加载中 / "加载更多"按钮(触底预取的手动兜底) / 到底提示。
  Widget _buildFooter(BuildContext context) {
    if (!_hasMore) {
      final endText = widget.endText;
      if (endText == null) return const SizedBox(height: 24);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(endText, style: Theme.of(context).textTheme.labelSmall),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton(onPressed: _loadMore, child: Text(widget.moreText)),
      ),
    );
  }
}
