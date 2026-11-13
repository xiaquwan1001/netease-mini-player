import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';

/// 封面卡片在 textScale=1.0 下的标准高度: 封面 118 + 4 间距 + 标题两行 + 副标题一行。
///
/// 卡片固定高度的容器(横向 [CoverRow] / 「我的」页各横滑区块)都用它,
/// 否则标题允许两行后会纵向溢出(RenderFlex overflowed).
const double kCoverCardHeight = 203;

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
  });

  final String? coverUrl;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// 封面边长, 同时作为卡片宽度。
  final double size;

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
            maxLines: 2,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
  });

  final List<Widget> children;
  final double height;
  final int rows;
  final double cardWidth;

  double _effectiveHeight(BuildContext context) {
    // 文字区三行(标题最多两行 + 副标题一行), 按字号等比放大.
    final textLines = MediaQuery.textScalerOf(context).scale(27) * 3;
    return height + (textLines - 81);
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
