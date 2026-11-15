import 'package:flutter/material.dart';

import '../cover_art.dart';
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../state_views.dart';
import '../user_nav.dart';
import 'message_shared.dart' show MessageErrorRow, relativeTime;
import 'message_types.dart';

// ---------------- @我 ----------------

class ForwardsTab extends StatefulWidget {
  const ForwardsTab({super.key, required this.load});

  final ForwardsLoader load;

  @override
  State<ForwardsTab> createState() => ForwardsTabState();
}

class ForwardsTabState extends State<ForwardsTab> {
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
      return MessageErrorRow(message: _error!, onRetry: _load);
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
