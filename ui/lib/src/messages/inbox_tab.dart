import 'package:flutter/material.dart';

import '../comment_page.dart';
import '../cover_art.dart';
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../state_views.dart';
import '../user_nav.dart';
import 'message_shared.dart' show MessageErrorRow, relativeTime;
import 'message_types.dart';

// ---------------- 通知 / 评论 ----------------

class InboxTab extends StatefulWidget {
  const InboxTab({
    super.key,
    required this.load,
    required this.emptyText,
    required this.icon,
  });

  final InboxLoader load;
  final String emptyText;
  final IconData icon;

  @override
  State<InboxTab> createState() => InboxTabState();
}

class InboxTabState extends State<InboxTab> {
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
      return MessageErrorRow(message: _error!, onRetry: _load);
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
