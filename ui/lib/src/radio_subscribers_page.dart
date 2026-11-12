import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;
import 'user_page.dart';

/// 订阅者/听众列表加载器(测试用 mock). timeMs 是分页游标(上一页最后一条的
/// subscribeTimeMs, 首屏传 -1). 注意: 当前 FFI radioSubscribers 只有
/// radioId+limit, 暂不支持 time 入参, 默认加载器忽略游标并对 userId 去重.
typedef LoadRadioSubscribers = Future<rust.RadioSubscriberPage?> Function(
  BigInt radioId,
  BigInt timeMs,
);

/// 打开某电台的订阅者/听众列表页(只读, 不做关注)
///
/// 每行可点进**他人主页**(user_page.dart)。
Future<void> showRadioSubscribers(
  BuildContext context, {
  required BigInt radioId,
  String radioName = '',
  LoadRadioSubscribers? loadSubscribers,
  void Function(List<rust.SongDto> songs, int index)? onPlaySongs,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RadioSubscribersPage(
        radioId: radioId,
        radioName: radioName,
        loadSubscribers: loadSubscribers,
        onPlaySongs: onPlaySongs,
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
    this.onPlaySongs,
  });

  final BigInt radioId;
  final String radioName;

  /// 注入加载器(测试用 mock); 不传走 FFI radioSubscribers
  final LoadRadioSubscribers? loadSubscribers;

  /// 进他人主页后点歌单要能播(宿主注入)
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  @override
  State<RadioSubscribersPage> createState() => _RadioSubscribersPageState();
}

class _RadioSubscribersPageState extends State<RadioSubscribersPage> {
  static const int _pageSize = 30;

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

  /// 手写分页壳曾与 PagedListView 重复(还漏了去重); 现在直接交给公共组件。
  Future<PagedPage<rust.RadioSubscriber>> _page(int cursor) async {
    final timeMs = cursor == 0 ? BigInt.from(-1) : BigInt.from(cursor);
    final page = await _load(widget.radioId, timeMs);
    if (page == null) return const PagedPage([], hasMore: false);
    final subs = page.subscribers;
    return PagedPage(
      subs,
      hasMore: page.hasMore,
      // 游标用"本页最后一条的 subscribeTimeMs"; 空页就停在原地
      nextCursor: subs.isEmpty ? cursor : subs.last.subscribeTimeMs.toInt(),
    );
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
      body: PagedListView<rust.RadioSubscriber>(
        loader: _page,
        pageSize: _pageSize,
        keyOf: (s) => s.userId,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        endText: null,
        emptyBuilder: (context, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.group_outlined,
                size: 48,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 12),
              const Text('还没有听众'),
            ],
          ),
        ),
        itemBuilder: (context, s, i, items) => _SubscriberRow(
          subscriber: s,
          onOpen: () => showUserPage(
            context,
            userId: s.userId,
            fallbackNickname: s.nickname,
            onPlaySongs: widget.onPlaySongs,
          ),
        ),
      ),
    );
  }
}

class _SubscriberRow extends StatelessWidget {
  const _SubscriberRow({required this.subscriber, this.onOpen});

  final rust.RadioSubscriber subscriber;

  /// 点进他人主页(不传则不可点, 供测试/无路由场景)
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final subtitle = subscriber.signature.trim().isEmpty
        ? '暂无简介'
        : subscriber.signature.trim();
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CoverArt(url: subscriber.avatarUrl, size: 40, radius: 20),
      title: Text(
        subscriber.nickname,
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
      ),
      subtitle: Text(subtitle, overflow: TextOverflow.ellipsis, maxLines: 1),
      onTap: onOpen,
    );
  }
}
