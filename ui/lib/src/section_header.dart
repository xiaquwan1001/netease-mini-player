import 'package:flutter/material.dart';

import 'layout.dart';

/// 全仓唯一的「区块标题 + 可选尾部动作」实现(需求 10)。
///
/// 之前 `mine_view.dart` / `recommend_view.dart` / `artist_sections.dart` 各有一份
/// 私有副本, 基线规则互不相同(有的 `CrossAxisAlignment.end` + 40dp 的 TextButton,
/// 于是「查看全部」比标题低 6.5~12dp, 视觉上不在同一条水平线)。
/// 现在统一: 标题 [Expanded] + 尾部固定宽度上限 + `CrossAxisAlignment.center`,
/// 标题与 trailing 的中心线严格对齐。
///
/// 标题左侧不带左右 padding: 由调用方按页面栅格([kPagePadding])摆位,
/// 这样「我的」页里标题(12)与卡片内容(12+4)共用同一条左边线。
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = kSectionHeaderPadding,
  });

  final String title;

  /// 尾部动作(通常是 [SectionSeeAllButton]); 垂直方向与标题居中对齐。
  final Widget? trailing;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _titleRow(
      padding: padding,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      trailing: trailing,
    );
  }
}

/// 「标题 + 可选尾部动作」的公共布局(区块标题与小组标题共用)。
///
/// 尾部最多吃掉 60% 宽度(原来 45% 会逼着「播放全部 + 查看全部 n 首 ›」
/// 被 FittedBox 等比缩小, 用户反馈按钮字太小)。标题至少保留 40%。
/// 无 trailing 时退化成纯 [Padding], 与历史渲染结果一致。
Widget _titleRow({
  required EdgeInsetsGeometry padding,
  required Widget title,
  required Widget? trailing,
}) {
  if (trailing == null) {
    return Padding(padding: padding, child: title);
  }
  return Padding(
    padding: padding,
    child: LayoutBuilder(
      builder: (context, constraints) {
        final maxActionWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth * 0.6
            : double.infinity;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: title),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxActionWidth),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: trailing,
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// 小组标题(卡片/分组内部的一级, 如「界面」「通用」「关于」「账号簿」).
///
/// 与 [SectionHeader](区块标题, titleMedium)区分: 这里是 titleSmall + w600。
/// 之前 6 个页面各有一份私有 `_SectionTitle`, padding 却有 6/8 两种,
/// 于是同一套「标题 + 卡片」在不同页面里间距不一致。
class SectionTitle extends StatelessWidget {
  const SectionTitle(
    this.title, {
    super.key,
    this.trailing,
    this.padding = kSectionTitlePadding,
  });

  final String title;

  /// 尾部动作(计数文字、开关按钮等); 垂直方向与标题居中对齐。
  final Widget? trailing;

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return _titleRow(
      padding: padding,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      trailing: trailing,
    );
  }
}

/// 区块标题右侧的文字动作(「查看全部」「全部 123 首 ›」)。
///
/// 用 compact 密度 + shrinkWrap 点击区, 让按钮盒高(约 32)接近标题行高,
/// 不再用默认 40dp 的盒把整行撑高。
class SectionSeeAllButton extends StatelessWidget {
  const SectionSeeAllButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: Size.zero,
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}
