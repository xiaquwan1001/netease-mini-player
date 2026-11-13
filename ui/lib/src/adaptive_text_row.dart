import 'package:flutter/material.dart';

import 'adaptive_text.dart';

/// 徽标组的默认收起阈值(逻辑 px) —— 口径已收敛到 [AdaptiveText].
///
/// 判据是「标题实际可用宽」(= 行宽 - Σ徽标宽), 见 [titleAvailableWidth].
export 'adaptive_text.dart'
    show
        AdaptiveText,
        AdaptiveTextMode,
        badgeGroupWidth,
        kBadgeCollapseBelowDefault,
        needsMarquee,
        shouldShowBadgesForWidth,
        titleAvailableWidth;

/// 纯函数(兼容旧接口, 便于单测): 标题区可用 [availableWidth] px 时, 徽标组是否还能显示.
///
/// 新版口径在 [shouldShowBadgesForWidth](输入行宽 + 实测徽标宽); 这里保留
/// "已算好的标题可用宽"版本, 供原来按可用宽断言的单测/调用方继续用.
bool shouldShowBadges(
  double availableWidth, {
  double threshold = kBadgeCollapseBelowDefault,
}) {
  return availableWidth >= threshold;
}

/// 「标题文本 + 一串装饰徽标」的窄宽降级行 —— [AdaptiveText] 的薄封装.
///
/// - 标题永远 Expanded + 单行: [marquee] 为 true 时走 [AdaptiveTextMode.marquee]
///   (放不下才滚动, 退化路径是 ellipsis); false 时退化为单行 ellipsis;
/// - 标题实际可用宽 >= [badgeCollapseBelow] 时徽标组照常显示; 不足时整组隐藏
///   (装饰性信息可丢, 标题可读性不可丢), 绝不让 Row 把标题挤到 0 宽;
/// - 徽标自身的间距(如 VipBadge 的 margin)由徽标自己负责, 组件只保证
///   徽标与标题之间至少有 [badgeGap].
/// 新代码请直接用 [AdaptiveText(badges: …)]; 本类保留以兼容既有调用点与单测.
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

  /// 标题实际可用宽低于该值(逻辑 px)时收起整组徽标.
  final double badgeCollapseBelow;

  /// true: 标题放不下时跑马灯滚动; false: 退化为单行 ellipsis.
  final bool marquee;

  /// 标题与第一个徽标之间的最小间距.
  final double badgeGap;

  @override
  Widget build(BuildContext context) {
    return AdaptiveText(
      title,
      mode: marquee ? AdaptiveTextMode.marquee : AdaptiveTextMode.ellipsis,
      style: style,
      badges: badges,
      badgeCollapseBelow: badgeCollapseBelow,
      badgeGap: badgeGap,
    );
  }
}
