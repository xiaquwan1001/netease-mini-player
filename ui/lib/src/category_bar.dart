import 'package:flutter/material.dart';

import 'layout.dart';

/// 分类 tab 条(搜索结果的「单曲/艺人/…」与输入联想的分类共用同一套).
///
/// 2026-11-14 用户反馈两条, 根因都在几何上, 所以这里统一收口:
/// 1. 「分类前面有奇怪的缩进, 没有对齐, 也没利用显示宽度」——
///    父级 `Column`(`crossAxisAlignment` 默认 center) 给子节点的是**松约束**,
///    `Padding + Wrap` 只会收缩到自己内容宽度 ⇒ 整条被**居中**, 左边界跟着行宽漂;
///    选中第二排的分类时行宽变了, 看起来"缩进消失/两排又对齐了"。
///    修法: [SizedBox] 撑满 + `WrapAlignment.start`。
/// 2. 「切分类时整条会跳」—— 默认的 checkmark 让选中 chip 变宽, 每次切换都要重排。
///    这里 `showCheckmark: false`, 选中只靠底色/文字色表达。
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

  @override
  Widget build(BuildContext context) {
    final counts = this.counts;
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kPagePadding, 6, kPagePadding, 6),
        child: Wrap(
          alignment: WrapAlignment.start,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var i = 0; i < labels.length; i++)
              ChoiceChip(
                label: Text(_labelFor(i, counts)),
                selected: i == selected,
                showCheckmark: false,
                // 已选中时再点不做事(避免重建丢滚动位置)
                onSelected: (_) {
                  if (i != selected) onSelected(i);
                },
                visualDensity: VisualDensity.compact,
              ),
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
