import 'package:flutter/material.dart';

/// 带分段选择器的设置行(主题模式 / 关闭主窗口时 共用).
///
/// 之前用 `ListTile(trailing: SegmentedButton(...))`: 窄屏 + 大字号下(例如
/// vivo 真机 1440x3168 @ density 768 ⇒ 300dp 宽, 系统字号 1.25)trailing 被要求
/// 吃掉整行宽度, ListTile 直接抛
/// "Trailing widget consumes the entire tile width", 该 ListTile 及其后的
/// render box 都不再布局 ⇒ 文案竖排、内容越界。
/// 所以分段控件单独占一行, 宽度跟着内容走, 极端字号下退化为横向滚动。
class SegmentedSettingTile<T> extends StatelessWidget {
  const SegmentedSettingTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.segments,
    required this.selected,
    required this.onSelectionChanged,
  });

  final String title;
  final String subtitle;
  final List<ButtonSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onSelectionChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 外层 Card 的 Column 是交叉轴 center, 不给满宽就会整行被居中
    // (表现为「主题模式」这行相对上下 ListTile 缩进/不对齐)。
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<T>(
                showSelectedIcon: false,
                segments: segments,
                selected: {selected},
                onSelectionChanged: (value) => onSelectionChanged(value.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
