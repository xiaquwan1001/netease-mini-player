import 'package:flutter/material.dart';

import 'comment_page.dart';
import 'cover_art.dart';
import 'layout.dart' show avatarStripHeightFor;
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'state_views.dart';
import 'toast.dart' show showToast;
import 'user_nav.dart';

typedef MessageCountsLoader = Future<rust.MessageCountsDto> Function();
typedef SessionsPageLoader = Future<List<rust.PrivateSession>> Function(
  int limit,
  int offset,
);
typedef ContactsLoader = Future<List<rust.RecentContact>> Function();
typedef ForwardsLoader = Future<List<rust.ForwardItem>> Function();
typedef HistoryPageLoader = Future<List<rust.PrivateMessage>> Function(
  BigInt userId,
  int limit,
  BigInt beforeMs,
);
typedef InboxLoader = Future<List<rust.InboxItem>> Function();
typedef PrivateSender = Future<bool> Function(BigInt userId, String content);

/// 消息中心: 私信 / 通知 / 评论 / @我 四个页签.
///
/// 私信**可回复**(2026-11): 上游 /api/msg/private/send(api-enhanced send_text),
/// 见 ncm-ffi 的 privateSend。通知/评论/@我 仍是只读(缺 thread_id/comment_id,
/// 见 .pi/analysis/2026-11-13/msg.md)。
/// 未登录时每个页签各自给一句登录提示, 不整页报错.
/// 私信会话与聊天记录支持分页: 触底或按钮触发, 返回条数 < limit 视为到底.
Future<void> showMessagesPage(
  BuildContext context, {
  MessageCountsLoader? loadCounts,
  SessionsPageLoader? loadSessions,
  ContactsLoader? loadContacts,
  HistoryPageLoader? loadHistory,
  InboxLoader? loadNotices,
  InboxLoader? loadComments,
  ForwardsLoader? loadForwards,
  PrivateSender? sendPrivate,
  int pageSize = 30,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MessagesPage(
        loadCounts: loadCounts,
        loadSessions: loadSessions,
        loadContacts: loadContacts,
        loadHistory: loadHistory,
        sendPrivate: sendPrivate,
        loadNotices: loadNotices,
        loadComments: loadComments,
        loadForwards: loadForwards,
        pageSize: pageSize,
      ),
    ),
  );
}

class MessagesPage extends StatefulWidget {
  const MessagesPage({
    super.key,
    this.loadCounts,
    this.loadSessions,
    this.loadContacts,
    this.loadHistory,
    this.sendPrivate,
    this.loadNotices,
    this.loadComments,
    this.loadForwards,
    this.pageSize = 30,
  });

  final MessageCountsLoader? loadCounts;
  final SessionsPageLoader? loadSessions;
  final ContactsLoader? loadContacts;
  final HistoryPageLoader? loadHistory;
  final PrivateSender? sendPrivate;
  final InboxLoader? loadNotices;
  final InboxLoader? loadComments;
  final ForwardsLoader? loadForwards;

  /// 会话/聊天记录每页条数(也是"返回条数 < limit 视为到底"的阈值)
  final int pageSize;

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  rust.MessageCountsDto? _counts;

  SessionsPageLoader get _sessions =>
      widget.loadSessions ??
      (limit, offset) => rust.privateSessions(limit: limit, offset: offset);
  ContactsLoader get _contacts =>
      widget.loadContacts ?? () => rust.recentContacts(limit: widget.pageSize);
  HistoryPageLoader get _history =>
      widget.loadHistory ??
      (uid, limit, before) =>
          rust.privateHistory(userId: uid, limit: limit, beforeMs: before);
  InboxLoader get _notices =>
      widget.loadNotices ??
      () =>
          rust.messageNotices(limit: widget.pageSize, lastTimeMs: BigInt.zero);
  InboxLoader get _comments =>
      widget.loadComments ?? () => rust.commentMessages(limit: widget.pageSize);
  ForwardsLoader get _forwards =>
      widget.loadForwards ??
      () =>
          rust.forwardMessages(limit: widget.pageSize, lastTimeMs: BigInt.zero);

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
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('消息'),
          bottom: TabBar(
            tabs: [
              Tab(text: _label('私信', counts?.private)),
              Tab(text: _label('通知', counts?.notices)),
              Tab(text: _label('评论', counts?.comments)),
              Tab(text: _label('@我', counts?.forwards)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _SessionsTab(
              load: _sessions,
              loadHistory: _history,
              send: widget.sendPrivate,
              loadContacts: _contacts,
              pageSize: widget.pageSize,
            ),
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
            _ForwardsTab(load: _forwards),
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
  const _SessionsTab({
    required this.load,
    required this.loadHistory,
    this.send,
    required this.loadContacts,
    required this.pageSize,
  });

  final SessionsPageLoader load;
  final HistoryPageLoader loadHistory;
  final PrivateSender? send;
  final ContactsLoader loadContacts;
  final int pageSize;

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab> {
  List<rust.RecentContact> _contacts = const [];

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  /// 最近联系人横滑条: 拿不到就不显示, 不影响会话列表
  Future<void> _loadContacts() async {
    try {
      final contacts = await retryNetwork(widget.loadContacts);
      if (!mounted) return;
      setState(() => _contacts = contacts);
    } catch (_) {}
  }

  /// 分页闭包: offset 按服务端已消费行数追加(与去重后的列表长度无关),
  /// 去重交给 PagedListView.keyOf。
  PagedLoader<rust.PrivateSession> get _sessionLoader {
    final load = widget.load;
    final pageSize = widget.pageSize;
    return (cursor) async {
      final page = await retryNetwork(() => load(pageSize, cursor));
      return PagedPage(
        page,
        hasMore: page.length >= pageSize,
        nextCursor: cursor + page.length,
      );
    };
  }

  @override
  Widget build(BuildContext context) {
    final contacts = _contacts;
    return PagedListView<rust.PrivateSession>(
      loader: _sessionLoader,
      keyOf: (s) => s.userId,
      emptyText: '还没有私信',
      endText: '没有更多了',
      separator: const Divider(height: 1, indent: 68),
      header: contacts.isEmpty
          ? null
          : _ContactsStrip(
              contacts: contacts,
              // 联系人条: 头像进主页, 其余区域(名字)直接开聊天
              onOpenChat: (c) => showPrivateChat(
                context,
                session: rust.PrivateSession(
                  userId: c.userId,
                  nickname: (c.remarkName != null && c.remarkName!.isNotEmpty)
                      ? c.remarkName!
                      : c.nickname,
                  avatarUrl: c.avatarUrl,
                  lastMessage: '',
                  lastTimeMs: BigInt.zero,
                  unread: 0,
                ),
                load: widget.loadHistory,
                send: widget.send,
                pageSize: widget.pageSize,
              ),
            ),
      itemBuilder: (context, s, index, items) => ListTile(
        // 头像点进用户主页, 整行仍然弹聊天面板
        leading: UserAvatarTap(
          userId: s.userId,
          nickname: s.nickname,
          child: CircleCover(
            url: s.avatarUrl,
            size: 44,
            icon: Icons.person_outline,
          ),
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
          load: widget.loadHistory,
          send: widget.send,
          pageSize: widget.pageSize,
        ),
      ),
    );
  }
}

/// 私信页顶部"最近联系人"横滑条(顺序 = 服务端顺序, 前端不重排; 备注名优先)
class _ContactsStrip extends StatelessWidget {
  const _ContactsStrip({required this.contacts, required this.onOpenChat});

  final List<rust.RecentContact> contacts;

  /// 点名字/空白处 → 打开聊天面板(头像另有主页跳转, 见 [UserAvatarTap])
  final void Function(rust.RecentContact) onOpenChat;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      // 头像 44 + 间距 4 + 11sp 标签: 定 84 在 1.625 字号下竖向溢出(与艺人筛选条同款)
      height: avatarStripHeightFor(context),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: contacts.length,
        itemBuilder: (context, i) {
          final c = contacts[i];
          final remark = c.remarkName;
          final name = (remark != null && remark.isNotEmpty)
              ? remark
              : c.nickname;
          return SizedBox(
            width: 68,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onOpenChat(c),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    UserAvatarTap(
                      userId: c.userId,
                      nickname: name,
                      child: CircleCover(
                        url: c.avatarUrl,
                        size: 44,
                        icon: Icons.person_outline,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 单人私信历史(只读; 官方 App 才允许回复)
Future<void> showPrivateChat(
  BuildContext context, {
  required rust.PrivateSession session,
  required HistoryPageLoader load,
  PrivateSender? send,
  int pageSize = 30,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: Column(
          children: [
            SheetHeader(
              title: session.nickname,
              leading: CircleCover(
                url: session.avatarUrl,
                size: 36,
                icon: Icons.person_outline,
              ),
              onClose: () => Navigator.pop(context),
            ),
            const Divider(height: 1),
            Expanded(
              child: _ChatBody(
                session: session,
                load: load,
                send: send,
                pageSize: pageSize,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ChatBody extends StatefulWidget {
  const _ChatBody({
    required this.session,
    required this.load,
    required this.pageSize,
    this.send,
  });

  final rust.PrivateSession session;
  final HistoryPageLoader load;
  final int pageSize;

  /// 发送私信(为 null 时退回只读: 测试/宿主未注入时不显示输入框)
  final PrivateSender? send;

  @override
  State<_ChatBody> createState() => _ChatBodyState();
}

class _ChatBodyState extends State<_ChatBody> {
  List<rust.PrivateMessage>? _items;
  String? _error;
  bool _loadingOlder = false;
  bool _noMore = false;
  bool _sending = false;
  final TextEditingController _input = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  PrivateSender get _sender => widget.send ?? _rustSend;

  Future<bool> _rustSend(BigInt userId, String content) =>
      rust.privateSend(userId: userId, content: content);

  /// 发送一条私信: 成功后重拉最新一页(服务端回显才算数, 不做本地乐观插入)
  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final ok = await _sender(widget.session.userId, text);
      if (!mounted) return;
      if (ok) {
        _input.clear();
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, friendlyError(e), isError: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await retryNetwork(
        () => widget.load(widget.session.userId, widget.pageSize, BigInt.zero),
      );
      if (!mounted) return;
      setState(() {
        _items = items;
        _noMore = items.length < widget.pageSize;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  /// 加载更早: 用当前最早一条的 time_ms 当 before_ms, 不重复拉最新一页
  Future<void> _loadOlder() async {
    final items = _items;
    if (items == null || items.isEmpty || _loadingOlder || _noMore) return;
    final before = items.first.timeMs;
    if (before <= BigInt.zero) {
      // 没有可用游标(异常数据), 不再翻页
      setState(() => _noMore = true);
      return;
    }
    setState(() => _loadingOlder = true);
    try {
      final page = await retryNetwork(
        () => widget.load(widget.session.userId, widget.pageSize, before),
      );
      if (!mounted) return;
      final known = items.map((m) => m.id).toSet();
      final fresh = page.where((m) => !known.contains(m.id)).toList();
      setState(() {
        _items = [...fresh, ...items];
        _loadingOlder = false;
        if (page.length < widget.pageSize) _noMore = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingOlder = false;
        _error = friendlyError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 列表 + 底部输入框: 输入框只在有真实 uid 时出现(缺 uid 的会话给一句提示)
    return Column(
      children: [
        Expanded(child: _buildList(context)),
        if (UserNav.canOpen(widget.session.userId))
          _buildComposer(context)
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Text(
              '这个会话无法回复(缺少用户 id)',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }

  /// 底部发送框: 空内容/发送中禁用; 成功后重拉最新一页(不做本地乐观插入)
  Widget _buildComposer(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '发私信…',
                  filled: true,
                  fillColor: scheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '发送',
              onPressed: _sending ? null : _send,
              icon: _sending
                  ? const SizedBox(
                      // token-ok: 行内 spinner 的方形尺寸(与 Material 默认 18 一致), 不是间距
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    if (_error != null) {
      return _ErrorRow(message: _error!, onRetry: _load);
    }
    final items = _items;
    if (items == null) {
      return const LoadingView();
    }
    if (items.isEmpty) {
      return const EmptyView(icon: Icons.notifications_none, title: '还没有消息');
    }
    final scheme = Theme.of(context).colorScheme;
    // 非分页: 私信按时间倒序锚底 + 向上"加载更早"(reverse + prepend), PagedListView 不支持该形态
    // 注意: 这个方法只负责列表本身, 外层 build 负责「列表 + 底部输入框」的 Column
    // reverse: 列表锚在底部(最新消息在下), 顶部是"加载更早"
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      reverse: true,
      itemCount: items.length + (_noMore ? 0 : 1),
      itemBuilder: (context, i) {
        if (i == items.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Center(
              child: _loadingOlder
                  ? const LoadingView.inline(size: 18)
                  : TextButton(
                      onPressed: _loadOlder,
                      child: const Text('加载更早'),
                    ),
            ),
          );
        }
        final m = items[items.length - 1 - i];
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
            child: Text(
              m.content,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
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
  List<rust.InboxItem>? _items;
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
      return const LoadingView();
    }
    if (items.isEmpty) {
      return EmptyView(title: widget.emptyText);
    }
    // 非分页: 评论消息一次全量返回, 无更多页
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 68),
      itemBuilder: (context, i) {
        final item = items[i];
        final theme = Theme.of(context);
        final subtitle = item.detail.isEmpty
            ? item.text
            : '${item.text}  ·  ${item.detail}';
        // 2026-11: InboxItem 补出 user_id / thread_id 后, 头像可点进主页,
        // 条目本身(有线程时)可点进对应评论区并直接回复。
        final threadId = item.threadId;
        final openable = threadId != null && threadId.isNotEmpty;
        return ListTile(
          leading: UserAvatarTap(
            userId: item.userId ?? BigInt.zero,
            nickname: item.actor.isEmpty ? null : item.actor,
            child: CircleCover(
              url: item.avatarUrl,
              size: 44,
              icon: widget.icon,
            ),
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                relativeTime(item.timeMs),
                style: theme.textTheme.labelSmall,
              ),
              if (openable) const Icon(Icons.chevron_right, size: 18),
            ],
          ),
          onTap: openable
              ? () => showCommentThreadPage(
                  context,
                  threadId: threadId,
                  title: item.kind == 'comment' ? '评论' : '相关评论',
                )
              : null,
        );
      },
    );
  }
}

// ---------------- @我 ----------------

class _ForwardsTab extends StatefulWidget {
  const _ForwardsTab({required this.load});

  final ForwardsLoader load;

  @override
  State<_ForwardsTab> createState() => _ForwardsTabState();
}

class _ForwardsTabState extends State<_ForwardsTab> {
  List<rust.ForwardItem>? _items;
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
      return const LoadingView();
    }
    if (items.isEmpty) {
      return const EmptyView(icon: Icons.alternate_email, title: '还没有@我');
    }
    // 非分页: @我 一次全量返回, 无更多页
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 68),
      itemBuilder: (context, i) {
        final f = items[i];
        final nickname = f.nickname;
        final comment = f.comment ?? '';
        final actor = (nickname == null || nickname.isEmpty)
            ? '云音乐用户'
            : nickname;
        return ListTile(
          leading: UserAvatarTap(
            userId: f.userId ?? BigInt.zero,
            nickname: actor,
            child: CircleCover(
              url: f.avatarUrl,
              size: 44,
              icon: Icons.alternate_email,
            ),
          ),
          title: Text(actor, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: comment.isEmpty
              ? null
              : Text(comment, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: Text(
            relativeTime(f.timeMs ?? BigInt.zero),
            style: Theme.of(context).textTheme.labelSmall,
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
