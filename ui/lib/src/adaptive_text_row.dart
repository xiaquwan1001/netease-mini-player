import 'package:flutter/material.dart';

import 'marquee_text.dart';

/// 徽标组的默认收起阈值(逻辑 px).
/// 上一轮 SongTile 实测: 标题区 <120px 时并排徽标会把歌名挤到 0 宽(竖排/消失).
const double kBadgeCollapseBelowDefault = 120;

/// 纯函数(便于单测): 标题区可用 [availableWidth] px 时, 徽标组是否还能显示.
/// 判定口径: 宽度不足阈值 => 整组装饰性徽标收起, 绝不允许把标题压到 0 宽.
bool shouldShowBadges(
  double availableWidth, {
  double threshold = kBadgeCollapseBelowDefault,
}) {
  return availableWidth >= threshold;
}

/// 「标题文本 + 一串装饰徽标」的窄宽降级行.
///
/// 上一轮 SongTile 的内联降级(song_tile.dart)收敛成共享组件:
///
/// - 标题永远 Expanded + 单行: 宽度够时走 [MarqueeText](放不下才滚动,
///   退化路径是 ellipsis), marquee: false 时退化为 Text(maxLines:1);
/// - 可用宽 >= [badgeCollapseBelow] 时徽标组照常显示; 不足时整组隐藏
///   (装饰性信息可丢, 标题可读性不可丢), 绝不让 Row 把标题挤到 0 宽;
/// - 徽标自身的间距(如 VipBadge 的 margin)由徽标自己负责, 组件只保证
///   徽标与标题之间至少有 [badgeGap].
class AdaptiveTextRow extends StatelessWidget {
  const AdaptiveTextRow({
    super.key,
    required this.title,
    this.style,
    this.badges = const [],
    this.badgeCollapseBelow = kBadgeCollapseBelowDefault,
    this.marquee = true,
    this.badgeGap = 4,
  });

  final String title;

  /// 标题文本样式.
  final TextStyle? style;

  /// 装饰性徽标( VIP / 付费 / 无版权 / 只读红心 …).
  /// 宽度不足时整组隐藏; 请只放装饰性内容, 不要放必须可见的操作入口.
  final List<Widget> badges;

  /// 可用宽度低于该值(逻辑 px)时收起整组徽标.
  final double badgeCollapseBelow;

  /// true: 标题放不下时跑马灯滚动; false: 退化为单行 ellipsis.
  final bool marquee;

  /// 标题与第一个徽标之间的最小间距.
  final double badgeGap;

  @override
  Widget build(BuildContext context) {
    final Widget titleWidget = marquee
        ? MarqueeText(title, style: style)
        : Text(
            title,
            style: style,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        // 判定独立成纯函数 shouldShowBadges, 便于阈值单测.
        final showBadges = shouldShowBadges(
          constraints.maxWidth,
          threshold: badgeCollapseBelow,
        );
        return Row(
          children: [
            // Expanded(而非 Flexible(loose)): loose 会在固定宽徽标的挤压下
            // 把标题压到 0 宽 —— 这是上一轮确认的竖排根因, 这里钉死.
            Expanded(child: titleWidget),
            if (showBadges)
              for (final badge in badges)
                Padding(
                  padding: EdgeInsets.only(left: badgeGap),
                  child: badge,
                ),
          ],
        );
      },
    );
  }
}
