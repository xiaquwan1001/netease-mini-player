import 'package:flutter/material.dart';

import '../async_view.dart';
import '../cover_art.dart';
import '../error_views.dart' show InlineError;
import '../layout.dart' show capRowTrailing;
import '../net_retry.dart' show friendlyError;
import '../rust/api.dart' as rust;
import '../state_views.dart';
import '../user_nav.dart';
import 'message_shared.dart' show relativeTime;
import 'message_types.dart';

// ---------------- @我 ----------------

/// 「@我」页签: 一次全量返回, 四态交给 [AsyncView](加载 = LoadingView,
/// 出错 = 一行错误 + 重试, 空 = 带图标的 EmptyView).
class ForwardsTab extends StatelessWidget {
  const ForwardsTab({super.key, required this.load});

  final ForwardsLoader load;

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<rust.ForwardItem>>(
      load: load,
      emptyText: '还没有@我',
      loadingBuilder: (_) => const LoadingView(),
      emptyBuilder: (_) =>
          const EmptyView(icon: Icons.alternate_email, title: '还没有@我'),
      // 页签级错误保持改造前的一行式(文案走 friendlyError, 右侧重试)
      errorBuilder: (_, error, retry) => Padding(
        padding: const EdgeInsets.all(16),
        child: InlineError(message: friendlyError(error), onRetry: retry),
      ),
      // 非分页: @我 一次全量返回, 无更多页
      builder: (context, items, _) => ListView.separated(
        itemCount: items.length,
        separatorBuilder: (_, _) => const Divider(height: 1, indent: 68),
        itemBuilder: (context, i) {
          final f = items[i];
          final nickname = f.nickname;
          final comment = f.comment ?? '';
          final actor = (nickname == null || nickname.isEmpty)
              ? '云音乐用户'
              : nickname;
          return LayoutBuilder(
            builder: (context, box) => ListTile(
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
              // 相对时间封顶 45%(列表行审计 B11)
              trailing: capRowTrailing(
                box.maxWidth,
                Text(
                  relativeTime(f.timeMs ?? BigInt.zero),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
