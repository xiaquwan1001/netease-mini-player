import 'package:flutter/material.dart';

/// 长文本「3 行截断 + 展开/收起」(简介/描述通用)。
///
/// 收敛前 artist_page 与 detail_page 各有一份逐字相同的私有实现
/// (2026-11 去重); 现在两页 + 用户主页共用这一份。
class ExpandableText extends StatefulWidget {
  const ExpandableText({super.key, required this.text, this.topPadding = 0});

  final String text;

  /// 需要与上文拉开距离时用(详情页给 8, 艺人页 0)。
  final double topPadding;

  @override
  State<ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<ExpandableText> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expanded = _expanded;
    return Padding(
      padding: EdgeInsets.only(top: widget.topPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: _toggle,
            child: Text(
              widget.text.trim(),
              maxLines: expanded ? null : 3,
              overflow: expanded ? null : TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: GestureDetector(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  expanded ? '收起' : '展开',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
