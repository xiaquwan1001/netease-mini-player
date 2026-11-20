import 'package:flutter/material.dart';

import 'messages/forwards_tab.dart' show ForwardsTab;
import 'messages/inbox_tab.dart' show InboxTab;
import 'messages/message_types.dart';
import 'messages/sessions_tab.dart' show SessionsTab;
import 'rust/api_all.dart' as rust;

// 对外入口保持不变(审计建议 3: 一页一文件后调用方零改动):
// 私信/通知/@我 页签、单人聊天、回调类型与相对时间文案仍从本文件 import。
export 'messages/forwards_tab.dart' show ForwardsTab;
export 'messages/inbox_tab.dart' show InboxTab;
export 'messages/message_shared.dart' show relativeTime;
export 'messages/message_types.dart';
export 'messages/private_chat.dart' show showPrivateChat;
export 'messages/sessions_tab.dart' show SessionsTab;

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
            SessionsTab(
              load: _sessions,
              loadHistory: _history,
              send: widget.sendPrivate,
              loadContacts: _contacts,
              pageSize: widget.pageSize,
            ),
            InboxTab(
              load: _notices,
              emptyText: '还没有通知',
              icon: Icons.notifications_none,
            ),
            InboxTab(
              load: _comments,
              emptyText: '还没有评论消息',
              icon: Icons.mode_comment_outlined,
            ),
            ForwardsTab(load: _forwards),
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
