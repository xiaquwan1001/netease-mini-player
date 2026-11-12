import 'package:flutter/material.dart';

import 'format.dart' show formatOneDecimal;

/// 评论统计条的视图模型(纯数据, 不依赖 Rust/网络).
///
/// 三个计数都可能缺数据: 调用方拿不到时就传 0, 组件会照常显示 0.
@immutable
class CommentStatsView {
  const CommentStatsView({
    this.commentCount = 0,
    this.shareCount = 0,
    this.likedCount = 0,
    this.hotCount = 0,
  });

  final int commentCount;
  final int shareCount;
  final int likedCount;
  final int hotCount;

  @override
  bool operator ==(Object other) =>
      other is CommentStatsView &&
      other.commentCount == commentCount &&
      other.shareCount == shareCount &&
      other.likedCount == likedCount &&
      other.hotCount == hotCount;

  @override
  int get hashCode =>
      Object.hash(commentCount, shareCount, likedCount, hotCount);
}

/// 紧凑数字: <1000 原样; 1000..9999 -> "x.x千"; >=10000 -> "x.x万";
/// 一位小数, 多余的 ".0" 去掉; 负数按 0 处理.
String formatCompactCount(int n) {
  if (n <= 0) return '0';
  if (n < 1000) return n.toString();
  if (n < 10000) return formatOneDecimal(n / 1000, '千');
  return formatOneDecimal(n / 10000, '万');
}

/// 热评角标文案"(热评 N)".
String formatHotBadge(int hotCount) => '(热评 ${formatCompactCount(hotCount)})';

/// 评论统计条: 一行三项「评论 / 分享 / 点赞」, 高度 <= 40dp.
///
/// - 三项都是 [InkWell] 包着的点击区; 对应回调为 null 时不渲染 InkWell(无点击、无水波纹).
/// - [CommentStatsView.hotCount] > 0 时在"评论"后补一个 "(热评 N)" 角标.
/// - 300dp + 1.25 字号不溢出: 每项文字走 Flexible + ellipsis, 整条再套一层 FittedBox.
class CommentStatsBar extends StatelessWidget {
  const CommentStatsBar({
    super.key,
    required this.view,
    this.onComments,
    this.onShare,
    this.onLikes,
  });

  /// 统计条最高高度(dp).
  static const double maxHeight = 40;

  final CommentStatsView view;
  final VoidCallback? onComments;
  final VoidCallback? onShare;
  final VoidCallback? onLikes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.labelMedium?.copyWith(
      color: scheme.onSurfaceVariant,
      fontSize: 12,
    );
    final suffixStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.primary,
      fontSize: 10,
    );
    final items = <Widget>[
      _StatsItem(
        key: const ValueKey<String>('comment-stats-comments'),
        icon: Icons.comment_outlined,
        label: '评论',
        value: formatCompactCount(view.commentCount),
        suffix: view.hotCount > 0 ? formatHotBadge(view.hotCount) : null,
        onTap: onComments,
        style: base,
        suffixStyle: suffixStyle,
      ),
      const SizedBox(width: 12),
      _StatsItem(
        key: const ValueKey<String>('comment-stats-share'),
        icon: Icons.share_outlined,
        label: '分享',
        value: formatCompactCount(view.shareCount),
        onTap: onShare,
        style: base,
      ),
      const SizedBox(width: 12),
      _StatsItem(
        key: const ValueKey<String>('comment-stats-likes'),
        icon: Icons.favorite_border,
        label: '点赞',
        value: formatCompactCount(view.likedCount),
        onTap: onLikes,
        style: base,
      ),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: maxHeight),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(mainAxisSize: MainAxisSize.min, children: items),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatsItem extends StatelessWidget {
  const _StatsItem({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.style,
    this.suffix,
    this.suffixStyle,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String value;
  final TextStyle? style;
  final String? suffix;
  final TextStyle? suffixStyle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 3),
        Flexible(
          child: Text(
            '$label $value',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: style,
          ),
        ),
        if (suffix != null) ...<Widget>[
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              suffix!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: suffixStyle,
            ),
          ),
        ],
      ],
    );
    if (onTap == null) return content;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
        child: content,
      ),
    );
  }
}
