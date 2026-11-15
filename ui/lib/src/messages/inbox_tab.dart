import 'package:flutter/material.dart';

import '../async_view.dart';
import '../comment_page.dart';
import '../cover_art.dart';
import '../error_views.dart' show InlineError;
import '../net_retry.dart' show friendlyError;
import '../rust/api.dart' as rust;
import '../state_views.dart';
import '../user_nav.dart';
import 'message_shared.dart' show relativeTime;
import 'message_types.dart';

// ---------------- 通知 / 评论 ----------------

/// 「通知」/「评论」页签(同一份实现, 文案与图标由调用方给): 一次全量返回,
/// 四态交给 [AsyncView](加载 = LoadingView, 出错 = 一行错误 + 重试,
/// 空 = EmptyView).
class InboxTab extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return AsyncView<List<rust.InboxItem>>(
      load: load,
      emptyText: emptyText,
      loadingBuilder: (_) => const LoadingView(),
      emptyBuilder: (_) => EmptyView(title: emptyText),
      // 页签级错误保持改造前的一行式(文案走 friendlyError, 右侧重试)
      errorBuilder: (_, error, retry) => Padding(
        padding: const EdgeInsets.all(16),
        child: InlineError(message: friendlyError(error), onRetry: retry),
      ),
      // 非分页: 评论消息一次全量返回, 无更多页
      builder: (context, items, _) => ListView.separated(
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
              child: CircleCover(url: item.avatarUrl, size: 44, icon: icon),
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
      ),
    );
  }
}
