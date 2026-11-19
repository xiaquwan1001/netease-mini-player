import 'package:flutter/material.dart';

import 'net_retry.dart';
import 'state_views.dart';
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
/// 自带布局、需要就地改条目的页面(如云盘页)不受这套 UI 约束, 但可以复用
/// 同文件的 [OffsetPager] 管分页状态。
/// 「(limit, offset) 取一页」风格的分页状态机(与 [PagedListView] 的 cursor 模式互补)。
///
/// [PagedListView] 只能整体重载、翻页靠服务端 cursor, 有几类页面用不了: 音乐云盘页要
/// 在列表里**就地删除**一行(整体重载会把用户已经拉到第 N 页的进度和滚动位置丢掉)、
/// 首行要显示每页随包带回的容量信息、上游也只给 `more` 标志而给不出 cursor。
/// 这类页面继续自己排版, 但不必再手写 offset 算术 —— 条目/offset/是否还有更多都交给这里。
///
/// 语义(与云盘页原先的手写实现逐条一致):
/// - [fetch] `reset: true` = 清空重来(offset 0); `reset: false` = 从**当前已加载条数**
///   续拉, 所以就地删除之后条数变了, 下一次追加仍然接着正确的位置;
/// - 只有取页成功才改动内部状态: 失败时旧条目原样保留, 错误抛给调用方决定怎么提示;
/// - [hasMore] 就是上一次取页给出的 `hasMore`, 调用方自己决定尾部件怎么画。
class OffsetPager<T extends Object> {
  OffsetPager({required this.pageSize, required this.load});

  /// 每页条数(透传给 [load] 的 limit)。
  final int pageSize;

  /// 取一页: 返回 (本页条目, 是否还有下一页)。
  final Future<({List<T> items, bool hasMore})> Function(int limit, int offset)
  load;

  final List<T> _items = <T>[];
  bool _hasMore = false;

  /// 已加载条目(只读视图; 改动请走 [fetch] / [removeWhere] / [clear])。
  List<T> get items => List<T>.unmodifiable(_items);

  int get length => _items.length;
  bool get hasMore => _hasMore;

  /// 拉一页并返回累计条目。[reset] 为真时清空重来(刷新/重试), 否则追加(加载更多)。
  Future<List<T>> fetch({required bool reset}) async {
    final offset = reset ? 0 : _items.length;
    final page = await load(pageSize, offset);
    if (reset) {
      _items
        ..clear()
        ..addAll(page.items);
    } else {
      _items.addAll(page.items);
    }
    _hasMore = page.hasMore;
    return items;
  }

  /// 就地删除(如云盘删歌): 不动已加载的其他条目, 也不触发重新取页。
  /// 返回是否有条目被删掉。
  bool removeWhere(bool Function(T item) test) {
    final before = _items.length;
    _items.removeWhere(test);
    return _items.length != before;
  }

  void clear() {
    _items.clear();
    _hasMore = false;
  }
}

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
    this.gridDelegateBuilder,
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

  /// 网格 delegate 构建器: 传入则用网格排版, 并拿到**真实可用宽度**。
  ///
  /// [availableWidth] = SliverConstraints.crossAxisExtent - 水平 padding,
  /// 即格子真正能铺开的宽度。需要按宽度算格子高/自适应封面的场景
  /// (见 layout.dart 的 [coverGridDelegate])必须用它, 不要用
  /// `MediaQuery.sizeOf(context).width` —— 整屏宽在窄视口/嵌在 tab 的页面里偏大,
  /// 会用算出过高的格子与溢出的固定尺寸封面。
  final SliverGridDelegate Function(
    BuildContext context,
    double availableWidth,
  )?
  gridDelegateBuilder;

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
      return const LoadingView();
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
      return EmptyView(title: widget.emptyText);
    }

    Widget body;
    final delegateBuilder = widget.gridDelegateBuilder;
    if (delegateBuilder != null || widget.gridDelegate != null) {
      final padding = widget.padding ?? EdgeInsets.zero;
      body = CustomScrollView(
        physics: widget.physics,
        slivers: [
          if (widget.header != null) SliverToBoxAdapter(child: widget.header!),
          // SliverLayoutBuilder 在 padding 之外: crossAxisExtent 是视口宽,
          // 减掉水平 padding 才是网格真正能铺开的宽度(传给 gridDelegateBuilder)。
          SliverLayoutBuilder(
            builder: (context, constraints) {
              final horizontal = padding
                  .resolve(Directionality.of(context))
                  .horizontal;
              final available = constraints.crossAxisExtent - horizontal;
              final delegate =
                  delegateBuilder?.call(context, available) ??
                  widget.gridDelegate!;
              return SliverPadding(
                padding: padding,
                sliver: SliverGrid.builder(
                  gridDelegate: delegate,
                  itemCount: _items.length,
                  itemBuilder: (context, i) =>
                      widget.itemBuilder(context, _items[i], i, _items),
                ),
              );
            },
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
            ? const LoadingView.inline(size: 20)
            : TextButton(onPressed: _loadMore, child: Text(widget.moreText)),
      ),
    );
  }
}
