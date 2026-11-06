import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

typedef MessageCountsLoader = Future<rust.MessageCountsDto> Function();
typedef SessionsLoader = Future<List<rust.PrivateSessionDto>> Function();
typedef HistoryLoader = Future<List<rust.PrivateMessageDto>> Function();
typedef HistoryByUserLoader = Future<List<rust.PrivateMessageDto>> Function(
    BigInt userId);
typedef InboxLoader = Future<List<rust.InboxItemDto>> Function();

/// 消息中心: 私信 / 通知 / 评论 三个页签(全部只读, 不在本 App 内回复).
/// 未登录时每个页签各自给一句登录提示, 不整页报错.
Future<void> showMessagesPage(
  BuildContext context, {
  MessageCountsLoader? loadCounts,
  SessionsLoader? loadSessions,
  HistoryByUserLoader? loadHistory,
  InboxLoader? loadNotices,
  InboxLoader? loadComments,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MessagesPage(
        loadCounts: loadCounts,
        loadSessions: loadSessions,
        loadHistory: loadHistory,
        loadNotices: loadNotices,
        loadComments: loadComments,
      ),
    ),
  );
}

class MessagesPage extends StatefulWidget {
  const MessagesPage({
    super.key,
    this.loadCounts,
    this.loadSessions,
    this.loadHistory,
    this.loadNotices,
    this.loadComments,
  });

  final MessageCountsLoader? loadCounts;
  final SessionsLoader? loadSessions;
  final HistoryByUserLoader? loadHistory;
  final InboxLoader? loadNotices;
  final InboxLoader? loadComments;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  rust.MessageCountsDto? _counts;

  SessionsLoader get _sessions =>
      widget.loadSessions ??
      () => rust.privateSessions(limit: 50, offset: 0);
  HistoryByUserLoader get _history =>
      widget.loadHistory ??
      (uid) => rust.privateHistory(userId: uid, limit: 50, beforeMs: BigInt.zero);
  InboxLoader get _notices =>
      widget.loadNotices ??
      () => rust.messageNotices(limit: 50, lastTimeMs: BigInt.zero);
  InboxLoader get _comments =>
      widget.loadComments ?? () => rust.commentMessages(limit: 50);

  @override
  void initState() {
    super.initState();
    _loadCounts();
  }

  Future<void> _loadCounts() async {
    try {
      final counts = await (widget.loadCounts ?? rust.messageCounts)();
      if (!mounted) return;
      setState(() => _counts = counts);
    } catch (_) {
      // 未登录/网络失败: 页签不显示数字即可
    }
  }

  @override
  Widget build(BuildContext context) {
    final counts = _counts;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('消息'),
          bottom: TabBar(
            tabs: [
              Tab(text: _label('私信', counts?.private)),
              Tab(text: _label('通知', counts?.notices)),
              Tab(text: _label('评论', counts?.comments)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _SessionsTab(load: _sessions, loadHistory: _history),
            _InboxTab(
              load: _notices,
              emptyText: '还没有通知',
              icon: Icons.notifications_none,
            ),
            _InboxTab(
              load: _comments,
              emptyText: '还没有评论消息',
              icon: Icons.mode_comment_outlined,
            ),
          ],
        ),
      ),
    );
  }

  String _label(String name, int? unread) {
    if (unread == null || unread <= 0) return name;
    return '$name $unread';
  }
}

/// 相对时间: 刚刚/n 分钟前/n 小时前/n 天前/日期
String relativeTime(BigInt timeMs) {
  if (timeMs <= BigInt.zero) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(timeMs.toInt());
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}

// ---------------- 私信 ----------------

class _SessionsTab extends StatefulWidget {
  const _SessionsTab({required this.load, required this.loadHistory});

  final SessionsLoader load;
  final HistoryByUserLoader loadHistory;

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> {
  List<rust.PrivateSessionDto>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorRow(message: _error!, onRetry: _load);
    }
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return const Center(child: Text('还没有私信'));
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 68),
      itemBuilder: (context, i) {
        final s = items[i];
        return ListTile(
          leading: CircleCover(
            url: s.avatarUrl,
            size: 44,
            icon: Icons.person_outline,
          ),
          title: Text(s.nickname, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            s.lastMessage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                relativeTime(s.lastTimeMs),
                style: Theme.of(context).textTheme.labelSmall,
              ),
              if (s.unread > 0) ...[
                const SizedBox(height: 4),
                Badge(label: Text('${s.unread}')),
              ],
            ],
          ),
          onTap: () => showPrivateChat(
            context,
            session: s,
            load: () => widget.loadHistory(s.userId),
          ),
        );
      },
    );
  }
}

/// 单人私信历史(只读; 官方 App 才允许回复)
Future<void> showPrivateChat(
  BuildContext context, {
  required rust.PrivateSessionDto session,
  required HistoryLoader load,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            ListTile(
              leading: CircleCover(
                url: session.avatarUrl,
                size: 36,
                icon: Icons.person_outline,
              ),
              title: Text(session.nickname),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _ChatBody(session: session, load: load)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Text(
                '这里只读: 回复请到官方客户端',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChatBody extends StatefulWidget {
  const _ChatBody({required this.session, required this.load});

  final rust.PrivateSessionDto session;
  final HistoryLoader load;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  List<rust.PrivateMessageDto>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorRow(message: _error!, onRetry: _load);
    }
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return const Center(child: Text('还没有消息'));
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final m = items[i];
        final mine = m.fromMe;
        return Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.72,
            ),
            decoration: BoxDecoration(
              color: mine
                  ? scheme.primaryContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(m.content, style: Theme.of(context).textTheme.bodyMedium),
          ),
        );
      },
    );
  }
}

// ---------------- 通知 / 评论 ----------------

class _InboxTab extends StatefulWidget {
  const _InboxTab({
    required this.load,
    required this.emptyText,
    required this.icon,
  });

  final InboxLoader load;
  final String emptyText;
  final IconData icon;

  @override
  State<_InboxTab> createState() => _InboxTabState();
}

class _InboxTabState extends State<_InboxTab> {
  List<rust.InboxItemDto>? _items;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _ErrorRow(message: _error!, onRetry: _load);
    }
    final items = _items;
    if (items == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (items.isEmpty) {
      return Center(child: Text(widget.emptyText));
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 68),
      itemBuilder: (context, i) {
        final item = items[i];
        final theme = Theme.of(context);
        final subtitle = item.detail.isEmpty ? item.text : '${item.text}  ·  ${item.detail}';
        return ListTile(
          leading: CircleCover(
            url: item.avatarUrl,
            size: 44,
            icon: widget.icon,
          ),
          title: Text(
            item.actor.isEmpty ? item.text : item.actor,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            item.actor.isEmpty ? item.detail : subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(
            relativeTime(item.timeMs),
            style: theme.textTheme.labelSmall,
          ),
        );
      },
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
