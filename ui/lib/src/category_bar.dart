import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'layout.dart';

/// 分类 tab 条(搜索结果的「单曲/艺人/…」与输入联想的分类共用同一套).
///
/// 2026-11-14 用户反馈三条, 都在这一个组件里收口:
/// 1. 「分类前面有奇怪的缩进, 没有对齐, 也没利用显示宽度」——
///    父级 `Column`(`crossAxisAlignment` 默认 center) 给子节点的是**松约束**,
///    `Padding + Wrap` 只会收缩到自己内容宽度 ⇒ 整条被**居中**, 左边界跟着行宽漂;
///    选中第二排的分类时行宽变了, 看起来"缩进消失/两排又对齐了"。
///    修法: [SizedBox] 撑满 + 每排都用 `Row` 显式铺开。
/// 2. 「切分类时整条会跳」—— 默认的 checkmark 让选中 chip 变宽, 每次切换都要重排。
///    这里 `showCheckmark: false`, 选中只靠底色/文字色表达。
/// 3. 「末尾有一个空缺」—— `Wrap` 按 chip 自然宽度左对齐换行, 7 个分类在 3 列下
///    排成 3/3/1, 最后一排右边空出两格, 看着像"少了一个分类"。
///    修法见 [_layoutRows]: 先按最宽 chip 算出每排最多几列, 再把条数**均分**到各排
///    (7 条 2 排 ⇒ 4+3, 3 排 ⇒ 3+2+2), 每排的 chip 用 `Expanded` 等分整行宽度,
///    于是**每一排都左贴页面留白、右贴页面留白**, 没有末尾空缺。
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

  /// chip 之间的横向间距, 与行距保持一致。
  static const double _gap = 6;

  /// 单 chip 的最小宽度: 两个字(如「MV」)也不至于被压成一条细缝。
  static const double _minChipWidth = 64;

  /// chip 文字两侧的留白估计: M3 ChoiceChip = labelPadding(8+8) + padding(4+4) + 边框(1+1)。
  /// 取得略大于真实值(宁可少排一列, 也不让文字被 ellipsis 截断)。
  static const double _labelInset = 40;

  @override
  Widget build(BuildContext context) {
    final counts = this.counts;
    final texts = [
      for (var i = 0; i < labels.length; i++) _labelFor(i, counts),
    ];
    if (texts.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kPagePadding, 6, kPagePadding, 6),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final rows = _layoutRows(context, texts, constraints.maxWidth);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var r = 0; r < rows.length; r++)
                  Padding(
                    // 行距走 Padding 而不是 Column spacing: 0 行时不留空。
                    padding: EdgeInsets.only(top: r == 0 ? 0 : _gap),
                    child: Row(
                      children: [
                        for (var c = 0; c < rows[r].length; c++) ...[
                          if (c > 0) const SizedBox(width: _gap),
                          Expanded(child: _chip(context, rows[r][c], texts)),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, int index, List<String> texts) {
    return ChoiceChip(
      // 居中 + 单行省略: chip 宽度由 Expanded 决定, 文案短时居中, 长时截断不溢出
      label: Text(
        texts[index],
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
      selected: index == selected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      // 已选中时再点不做事(避免重建丢滚动位置)
      onSelected: (_) {
        if (index != selected) onSelected(index);
      },
    );
  }

  /// 把 [texts] 的下标排成"每排都铺满整行"的行数组。
  ///
  /// 列数按**最宽的 chip** 算(保证任意一排都不会把文字挤成省略号), 再按行数把
  /// 条数均分: 多出来的 1 条依次分给前几排, 所以 7 条 2 排是 4+3、3 排是 3+2+2,
  /// 不会出现"最后一排只剩 1 个 chip、右边空一大格"的观感。
  List<List<int>> _layoutRows(
    BuildContext context,
    List<String> texts,
    double maxWidth,
  ) {
    final count = texts.length;
    if (count == 1) return [List<int>.generate(count, (i) => i)];
    final widest = texts
        .map((text) => _measuredWidth(context, text))
        .reduce(math.max);
    // 宽度未知(极端父约束)时退化成一行, 至少不会崩
    final columns = !maxWidth.isFinite || maxWidth <= 0
        ? count
        : (((maxWidth + _gap) / (widest + _gap)).floor()).clamp(1, count);
    final rowCount = (count / columns).ceil();
    final perRow = [
      for (var r = 0; r < rowCount; r++)
        count ~/ rowCount + (r < count % rowCount ? 1 : 0),
    ];
    final rows = <List<int>>[];
    var next = 0;
    for (final n in perRow) {
      rows.add([for (var i = 0; i < n; i++) next++]);
    }
    return rows;
  }

  /// 估算 chip 需要多宽: 文字实测宽 + 内边距, 不小于 [_minChipWidth]。
  double _measuredWidth(BuildContext context, String text) {
    final theme = Theme.of(context);
    final style =
        ChipTheme.of(context).labelStyle ??
        theme.textTheme.labelLarge ??
        const TextStyle();
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width + _labelInset;
    painter.dispose();
    return width < _minChipWidth ? _minChipWidth : width;
  }

  String _labelFor(int i, List<int>? counts) {
    final label = labels[i];
    if (counts == null || i >= counts.length || counts[i] <= 0) return label;
    return '$label ${counts[i]}';
  }
}
