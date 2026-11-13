import 'package:flutter/material.dart';

import 'marquee_text.dart';

/// 长文字在窄宽下的三种渲染形态(全 App 唯一判定口径).
enum AdaptiveTextMode {
  /// 单行 + ellipsis: 静态, 不滚(副标题/时间戳/统计数等).
  ellipsis,

  /// 单行 + 跑马灯: 交给 [MarqueeText], 由它自己测量/死区判定(放得下就不动).
  marquee,

  /// 多行(最多 [AdaptiveText.maxLines] 行)+ ellipsis: 封面卡片标题等.
  wrap,
}

/// 徽标组的默认收起阈值(逻辑 px).
///
/// 判据是**标题实际可用宽**(= 行宽 - Σ徽标宽), 不是整行宽 —— 见
/// [titleAvailableWidth]. 上一轮 SongTile 实测: 标题区 <120px 时并排徽标会把
/// 歌名挤到 0 宽(竖排/消失).
const double kBadgeCollapseBelowDefault = 120;

/// 纯函数: 标题实际可用宽 = 行宽 - 徽标组占用宽(负值钳 0).
///
/// 徽标组占用宽请用 [badgeGroupWidth] 算, 或直接传实测值(含间距).
double titleAvailableWidth(double rowWidth, double badgesWidth) {
  final available = rowWidth - badgesWidth;
  return available > 0 ? available : 0;
}

/// 纯函数: 徽标组占用宽 = Σ徽标宽 + 每个徽标前的间距.
double badgeGroupWidth(List<double> badgeWidths, {double gap = 4}) {
  var total = 0.0;
  for (final width in badgeWidths) {
    total += width + gap;
  }
  return total;
}

/// 纯函数: 徽标组是否展示.
///
/// 口径修正(本组件引入): 用「标题实际可用宽」判定, 而不是整行宽 ——
/// 整行宽 130 / Σ徽标 72 时标题只剩 58px, 按整行宽 130 判定会误判"够宽"
/// 而把标题压到 0 宽.
bool shouldShowBadgesForWidth(
  double rowWidth,
  double badgesWidth, {
  double threshold = kBadgeCollapseBelowDefault,
}) {
  return titleAvailableWidth(rowWidth, badgesWidth) >= threshold;
}

/// 纯函数: 是否需要跑马灯内核([MarqueeText]).
///
/// 唯一判定入口: 只有 [AdaptiveTextMode.marquee] 交给 [MarqueeText]
/// (它内部自己做"放得下/溢出死区/单向滚动"判定); 其余形态一律静态 [Text],
/// 不建 ticker.
bool needsMarquee(AdaptiveTextMode mode) => mode == AdaptiveTextMode.marquee;

/// 统一的长文字组件: 跑马灯 / 多行 / ellipsis 三形态 + 可选装饰徽标.
///
/// 收敛了此前三套各写一遍的实现:
/// - [MarqueeText]: 仍然是唯一的滚动内核(内部实现; 类保留, 测试按它做 finder);
/// - [AdaptiveTextRow]: 退化为本组件的薄封装(见 adaptive_text_row.dart);
/// - SongTitleWithBadges: 歌名部分改走本组件(徽标语义不同, 见该类注释).
///
/// 徽标收起判据统一走 [shouldShowBadgesForWidth], 输入是**实测徽标宽**:
/// 徽标先在一层 [Offstage] 里布局一次量出真宽(不绘制/不入语义, finder 默认
/// 跳过 offstage), 下一帧据此决定显示或整组收起 —— 不留"标题被挤到 0 宽"的帧.
class AdaptiveText extends StatelessWidget {
  const AdaptiveText(
    this.text, {
    super.key,
    this.mode = AdaptiveTextMode.marquee,
    this.style,
    this.maxLines = 1,
    this.badges = const [],
    this.badgeCollapseBelow = kBadgeCollapseBelowDefault,
    this.badgeGap = 4,
  });

  /// 待渲染文本.
  final String text;

  /// 渲染形态; 默认跑马灯(长文本才真的动).
  final AdaptiveTextMode mode;

  /// 文本样式(字号/颜色/灰显等由调用方给; 缺省继承 DefaultTextStyle).
  final TextStyle? style;

  /// [AdaptiveTextMode.wrap] 时的最大行数(其余形态恒为单行).
  final int maxLines;

  /// 装饰性徽标(VIP / 付费 / 无版权 / 只读红心 …). 只能放可丢的装饰内容.
  final List<Widget> badges;

  /// 标题实际可用宽低于该值时整组收起徽标.
  final double badgeCollapseBelow;

  /// 标题与每个徽标之间的最小间距.
  final double badgeGap;

  @override
  Widget build(BuildContext context) {
    final title = _buildTitle();
    if (badges.isEmpty) return title;
    return _BadgeRow(
      title: title,
      badges: badges,
      gap: badgeGap,
      threshold: badgeCollapseBelow,
    );
  }

  Widget _buildTitle() {
    // 单一判定: 只有 marquee 走滚动内核, 其余静态 Text.
    if (needsMarquee(mode)) {
      return MarqueeText(text, style: style, maxLines: maxLines);
    }
    final wrap = mode == AdaptiveTextMode.wrap;
    return Text(
      text,
      style: style,
      maxLines: wrap ? maxLines : 1,
      softWrap: wrap,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// [AdaptiveText] 的「标题 + 徽标」行: 标题 Expanded, 徽标固定宽.
///
/// 只在这里做徽标收起; 收起的判据输入是实测徽标宽(见 [AdaptiveText] 注释).
class _BadgeRow extends StatefulWidget {
  const _BadgeRow({
    required this.title,
    required this.badges,
    this.gap = 4,
    this.threshold = kBadgeCollapseBelowDefault,
  });

  final Widget title;
  final List<Widget> badges;
  final double gap;
  final double threshold;

  @override
  State<_BadgeRow> createState() => _BadgeRowState();
}

class _BadgeRowState extends State<_BadgeRow> {
  final GlobalKey _probeKey = GlobalKey();

  /// 实测徽标组占用宽(含间距); null = 还没量到(首帧先按"收起"渲染).
  double? _badgesWidth;

  /// 上次测量对应的徽标组签名(数量/间距/类型), 变了要重量.
  String get _signature =>
      '${widget.badges.length}:${widget.gap}:'
      '${widget.badges.map((b) => b.runtimeType).join(",")}';

  String? _measuredFor;

  void _measure() {
    if (!mounted) return;
    final render = _probeKey.currentContext?.findRenderObject();
    if (render is! RenderBox || !render.hasSize) return;
    final width = render.size.width;
    // 视口宽变化不需要重量徽标(徽标宽度与可用宽无关), 但签名变了必须重量.
    if (_measuredFor == _signature && _badgesWidth == width) return;
    setState(() {
      _badgesWidth = width;
      _measuredFor = _signature;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth;
        final measured = _measuredFor == _signature ? _badgesWidth : null;
        // 还没量到(首帧): 先按"收起"渲染 —— 未知宽时把徽标塞进窄行会溢出,
        // 下一帧量到真宽再决定显示. 宽度无界(UnconstrainedBox 等)时不收起.
        final showBadges =
            measured != null &&
            (!rowWidth.isFinite ||
                shouldShowBadgesForWidth(
                  rowWidth,
                  measured,
                  threshold: widget.threshold,
                ));
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        return Row(
          children: [
            // Expanded(而非 Flexible(loose)): 固定宽徽标不会把标题压到 0 宽.
            Expanded(child: widget.title),
            if (showBadges)
              for (final badge in widget.badges)
                Padding(
                  padding: EdgeInsets.only(left: widget.gap),
                  child: badge,
                ),
            // 徽标探测层: 始终布局(量真宽), 但 offstage ⇒ 不绘制/不入语义,
            // finder 默认跳过 offstage, 不会出现"同一枚徽标装两次"。
            // offstage 时 sizedByParent ⇒ 在 Row 里占 0 宽。
            if (widget.badges.isNotEmpty)
              Offstage(
                offstage: true,
                child: Row(
                  key: _probeKey,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final badge in widget.badges)
                      Padding(
                        padding: EdgeInsets.only(left: widget.gap),
                        child: badge,
                      ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
