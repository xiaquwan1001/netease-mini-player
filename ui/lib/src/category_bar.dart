import 'package:flutter/material.dart';

import 'layout.dart';

/// 分类 tab 条(搜索结果的「单曲/艺人/…」与输入联想的分类共用同一套).
///
/// 2026-11-14 用户四轮反馈收敛后的最终形态: **单横排 + 用户横向拖拽**。
/// 为什么不再换行/不再均分铺满(前两版的教训, 别再改回去):
/// 1. `Padding + Wrap` 在 `Column` 的松约束下会收缩到内容宽度并被**居中** ⇒
///    「分类前面有奇怪缩进」, 选中项带 checkmark 时宽度变化还会让左边界乱跳
///    (`showCheckmark: false` 保留, 选中/未选中同宽)。
/// 2. 换行版(`Wrap` 左对齐)在条数除不尽时最后一排右边**空一块**, 用户报「末尾空缺」;
///    改成"按列数均分 + 每排 Expanded 等分"后又把 chip 拉得很宽, 排版继续被吐槽。
/// 3. 所以彻底不做多排几何: 内容放不下就**横向滚动**, 由用户自己拖 ——
///    没有换行就没有"末尾空缺/两排对齐/宽度被拉伸"任何一类问题。
///    条数少时(<=一屏)表现与普通一行完全一致。
///
/// 可达性提示: 右侧被裁切的 chip 天然露出一截, 用户一眼能看出还能往左拖。
class CategoryBar extends StatelessWidget {
  const CategoryBar({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.counts,
  });

  final List<String> labels;

  /// 选中项下标(调用方保证 0 <= selected < labels.length)
  final int selected;
  final ValueChanged<int> onSelected;

  /// 每个分类的条目数(可选): 联想面板用它告诉用户"这一类有几条".
  final List<int>? counts;

  /// chip 之间的横向间距。
  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final counts = this.counts;
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        // 上下留白与页面对齐; 左右各留一屏边距, 拖到头不会贴边
        padding: const EdgeInsets.fromLTRB(kPagePadding, 6, kPagePadding, 6),
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              ChoiceChip(
                label: Text(_labelFor(i, counts)),
                selected: i == selected,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                // 已选中时再点不做事(避免重建丢滚动位置)
                onSelected: (_) {
                  if (i != selected) onSelected(i);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _labelFor(int i, List<int>? counts) {
    final label = labels[i];
    if (counts == null || i >= counts.length || counts[i] <= 0) return label;
    return '$label ${counts[i]}';
  }
}
