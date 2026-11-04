import 'package:flutter/material.dart';

/// 底部弹层用的轻量标题栏.
/// 不要在 showModalBottomSheet 里用 AppBar: sheet 内容高度不受限时,
/// AppBar 内部的 Column(spaceBetween + flex) 会抛
/// "RenderFlex children have non-zero flex but incoming height constraints are unbounded".
class SheetHeader extends StatelessWidget {
  const SheetHeader({
    super.key,
    required this.title,
    this.onBack,
    this.onClose,
  });

  final String title;
  final VoidCallback? onBack;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          else
            const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (onClose != null)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭',
              onPressed: onClose,
            ),
        ],
      ),
    );
  }
}
