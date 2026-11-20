import 'package:flutter/material.dart';

import '../cover_art.dart';
import '../layout.dart' show avatarStripHeightFor, capRowTrailing;
import '../net_retry.dart';
import '../paged_list_view.dart';
import '../rust/api_all.dart' as rust;
import '../user_nav.dart';
import 'message_shared.dart' show relativeTime;
import 'message_types.dart';
import 'private_chat.dart' show showPrivateChat;

// ---------------- 私信 ----------------

class SessionsTab extends StatefulWidget {
  const SessionsTab({
    super.key,
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
  State<SessionsTab> createState() => SessionsTabState();
}

class SessionsTabState extends State<SessionsTab> {
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
      itemBuilder: (context, s, index, items) => LayoutBuilder(
        builder: (context, box) => ListTile(
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
          // 相对时间宽度随「3天前」/日期变化, 封顶 45%(列表行审计 B11)
          trailing: capRowTrailing(
            box.maxWidth,
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  relativeTime(s.lastTimeMs),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                if (s.unread > 0) ...[
                  const SizedBox(height: 4),
                  Badge(label: Text('${s.unread}')),
                ],
              ],
            ),
          ),
          onTap: () => showPrivateChat(
            context,
            session: s,
            load: widget.loadHistory,
            send: widget.send,
            pageSize: widget.pageSize,
          ),
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
