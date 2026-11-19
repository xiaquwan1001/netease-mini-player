import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';

/// 封面卡片在 textScale=1.0 下的标准高度: 封面 118 + 4 间距 + 标题两行 + 副标题一行。
///
/// 卡片固定高度的容器(横向 [CoverRow] / 「我的」页各横滑区块)都用它,
/// 否则标题允许两行后会纵向溢出(RenderFlex overflowed).
///
/// 这个基准只对应「标题 2 行 + 副标题 1 行」; 要改行数请连同 [CoverRow] 的
/// [CoverRow.titleMaxLines]/[CoverRow.subtitleMaxLines] 一起传(高度会跟着行数走)。
const double kCoverCardHeight = 203;

/// 文字区一行在 textScale=1.0 下的设计高(高度口径的唯一基准, 见 [CoverRow])。
const double _kCoverTextLine = 27;

/// 封面卡片(封面 + 标题 + 副标题) —— 推荐页/搜索页/我的页共用。
///
/// 之前 recommend_view / chart_section / mine_view 各有一份逐字节相同的实现
/// (布局审计 A3), 统一到这里, 避免三处改样式漏改。
class CoverCard extends StatelessWidget {
  const CoverCard({
    super.key,
    required this.coverUrl,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.size = 118,
    this.titleMaxLines = 2,
    this.subtitleMaxLines = 1,
  });

  final String? coverUrl;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// 封面边长, 同时作为卡片宽度。
  final double size;

  /// 标题最多几行(默认 2, 与历史行为一致)。
  final int titleMaxLines;

  /// 副标题最多几行(默认 1 = 单行省略号, 与历史行为一致)。
  ///
  /// 推荐播客卡传 2: 副标题是「作者 · 集数」, 300dp/1.25 字号下 1 行放不下,
  /// 只能截成「四十只烤翅 · 3…」(2026-11-19 用户反馈)。
  /// **改这个值必须同时给 [CoverRow] 传同样的 [CoverRow.subtitleMaxLines]**,
  /// 否则容器按 1 行预留高度 ⇒ RenderFlex overflow。
  final int subtitleMaxLines;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverArt(url: coverUrl, size: size, radius: 8),
          const SizedBox(height: 4),
          // 封面卡片标题允许两行(用户反馈: 榜单/歌单长名字被截成一行, 认不出来)
          AdaptiveText(
            title,
            mode: AdaptiveTextMode.wrap,
            maxLines: titleMaxLines,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          // 单行副标题保持原来的 Text(像素零变化); 多行才走 AdaptiveText.wrap
          if (subtitleMaxLines <= 1)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            AdaptiveText(
              subtitle,
              mode: AdaptiveTextMode.wrap,
              maxLines: subtitleMaxLines,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

/// 一行(或两行)横滑封面卡片。
///
/// [height] 按 scale=1.0 设计(封面 118 + 4 + 两行文字约 54):
/// 大字体下文字行高变大, 固定高度会纵向溢出, 只放大"两行文字"的部分。
class CoverRow extends StatelessWidget {
  const CoverRow({
    super.key,
    required this.children,
    this.height = kCoverCardHeight,
    this.rows = 1,
    this.cardWidth = 118,
    this.titleMaxLines = 2,
    this.subtitleMaxLines = 1,
  });

  final List<Widget> children;
  final double height;
  final int rows;
  final double cardWidth;

  /// 卡片标题最多几行 —— **必须与 children 里 [CoverCard.titleMaxLines] 一致**,
  /// 本组件据此算固定高度(默认 2 = 历史行为)。
  final int titleMaxLines;

  /// 卡片副标题最多几行 —— 同上, 必须与 [CoverCard.subtitleMaxLines] 一致
  /// (默认 1 = 历史行为)。
  final int subtitleMaxLines;

  double _effectiveHeight(BuildContext context) {
    // 文字行数跟着卡片实际行数走: [height] 的基准是「2 行标题 + 1 行副标题」
    // (3 行 × 27), 每多/少一行就按系统字号等比增/减 27 × scale。
    // 默认参数下结果与旧公式逐像素相同(默认调用点不受影响)。
    final scale = MediaQuery.textScalerOf(context).scale(_kCoverTextLine);
    final baseLines = 2 + 1;
    final textLines = scale * (titleMaxLines + subtitleMaxLines);
    return height + (textLines - _kCoverTextLine * baseLines);
  }

  @override
  Widget build(BuildContext context) {
    final h = _effectiveHeight(context);
    if (rows <= 1 || children.length < 2) return _row(children, h);
    final half = (children.length + 1) ~/ 2;
    // 两排时内容高 = 2*height + 行间距(4), 外层必须把间距算进去(R1 溢出回归)。
    return SizedBox(
      height: h * 2 + 4,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(children.take(half).toList(), h),
          const SizedBox(height: 4),
          _row(children.skip(half).toList(), h),
        ],
      ),
    );
  }

  Widget _row(List<Widget> items, double h) {
    if (items.isEmpty) return SizedBox(height: h);
    return SizedBox(
      height: h,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (_, i) => SizedBox(width: cardWidth, child: items[i]),
      ),
    );
  }
}
