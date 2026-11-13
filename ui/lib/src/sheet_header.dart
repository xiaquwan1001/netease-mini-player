import 'package:flutter/material.dart';

/// 底部弹层用的轻量标题栏.
/// 不要在 showModalBottomSheet 里用 AppBar: sheet 内容高度不受限时,
/// AppBar 内部的 Column(spaceBetween + flex) 会抛
/// "RenderFlex children have non-zero flex but incoming height constraints are unbounded".
class SheetHeader extends StatelessWidget {
  const SheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.onBack,
    this.onClose,
    this.trailing,
  });

  final String title;

  /// 标题下的一行补充说明(如封面档位说明); 有则标题区两行排版.
  final String? subtitle;

  /// 标题左侧小件(封面/头像); 与 onBack 同时给时返回键优先.
  final Widget? leading;
  final VoidCallback? onBack;
  final VoidCallback? onClose;

  /// 关闭键左侧的附加内容(如加载小圈).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    );
    final Widget titleArea = subtitle == null
        ? Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: titleStyle,
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: titleStyle,
              ),
              const SizedBox(height: 2),
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ],
          );
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: '返回',
              onPressed: onBack,
            )
          else if (leading != null) ...[
            leading!,
            const SizedBox(width: 10),
          ] else
            const SizedBox(width: 12),
          Expanded(child: titleArea),
          if (trailing != null) ...[trailing!, const SizedBox(width: 8)],
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭',
              onPressed: onClose,
            ),
          if (onClose == null) const SizedBox(width: 12),
        ],
      ),
    );
  }
}
