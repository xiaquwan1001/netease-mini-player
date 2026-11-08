import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 订阅者/听众列表加载器(测试用 mock). timeMs 是分页游标(上一页最后一条的
/// subscribeTimeMs, 首屏传 -1). 注意: 当前 FFI radioSubscribers 只有
/// radioId+limit, 暂不支持 time 入参, 默认加载器忽略游标并对 userId 去重.
typedef LoadRadioSubscribers =
    Future<rust.RadioSubscriberPage?> Function(BigInt radioId, BigInt timeMs);

/// 打开某电台的订阅者/听众列表页(只读, 不做关注/跳转用户主页)
Future<void> showRadioSubscribers(
  BuildContext context, {
  required BigInt radioId,
  String radioName = '',
  LoadRadioSubscribers? loadSubscribers,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RadioSubscribersPage(
        radioId: radioId,
        radioName: radioName,
        loadSubscribers: loadSubscribers,
      ),
    ),
  );
}

class RadioSubscribersPage extends StatefulWidget {
  const RadioSubscribersPage({
    super.key,
    required this.radioId,
    this.radioName = '',
    this.loadSubscribers,
  });

  final BigInt radioId;
  final String radioName;

  /// 注入加载器(测试用 mock); 不传走 FFI radioSubscribers
  final LoadRadioSubscribers? loadSubscribers;

  @override
  State<RadioSubscribersPage> createState() => _RadioSubscribersPageState();
}

class _RadioSubscribersPageState extends State<RadioSubscribersPage> {
  static const int _pageSize = 30;

  final List<rust.RadioSubscriber> _items = [];
  final Set<BigInt> _seenIds = {};
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  /// 分页游标: 上一页最后一条的 subscribeTimeMs(首屏 -1)
  BigInt _timeMs = BigInt.from(-1);

  LoadRadioSubscribers get _load =>
      widget.loadSubscribers ??
      (radioId, timeMs) => retryNetwork(
            () => rust.radioSubscribers(
              radioId: radioId,
              limit: _pageSize,
              // 时间游标: 首屏 -1 表示从头, 之后传上一页最后一条的 subscribeTimeMs
              timeMs: timeMs < BigInt.zero ? null : timeMs,
            ),
          );

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
      _seenIds.clear();
      _timeMs = BigInt.from(-1);
    });
    try {
      final page = await _load(widget.radioId, _timeMs);
      if (!mounted) return;
      _applyPage(page);
      setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  void _applyPage(rust.RadioSubscriberPage? page) {
    if (page == null) {
      _hasMore = false;
      return;
    }
    for (final s in page.subscribers) {
      // FFI 暂无 time 游标入参时重复拉到同一页, 按 userId 去重
      if (_seenIds.add(s.userId)) _items.add(s);
    }
    _hasMore = page.hasMore;
    if (page.subscribers.isNotEmpty) {
      _timeMs = page.subscribers.last.subscribeTimeMs;
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await _load(widget.radioId, _timeMs);
      if (!mounted) return;
      _applyPage(page);
      setState(() => _loadingMore = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('加载更多失败: ${friendlyError(e)}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.radioName.isEmpty ? '听众' : '「${widget.radioName}」的听众',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.cloud_off, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text('加载失败: $_error', textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          Center(child: FilledButton(onPressed: _reload, child: const Text('重试'))),
        ],
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.group_outlined, size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            const Text('还没有听众'),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: _loadingMore
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(onPressed: _loadMore, child: const Text('加载更多')),
              ),
            );
          }
          return _SubscriberRow(subscriber: _items[i]);
        },
      ),
    );
  }
}

class _SubscriberRow extends StatelessWidget {
  const _SubscriberRow({required this.subscriber});

  final rust.RadioSubscriber subscriber;

  @override
  Widget build(BuildContext context) {
    final subtitle = subscriber.signature.trim().isEmpty ? '暂无简介' : subscriber.signature.trim();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CoverArt(url: subscriber.avatarUrl, size: 40, radius: 20),
      title: Text(subscriber.nickname, overflow: TextOverflow.ellipsis, maxLines: 1),
      subtitle: Text(subtitle, overflow: TextOverflow.ellipsis, maxLines: 1),
      // TODO(跳转): 现有 UI 无用户主页路由, 点击暂不跳转, 后续接入后补 onOpenUser
      onTap: null,
    );
  }
}
