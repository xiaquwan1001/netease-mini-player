import 'package:flutter/material.dart';

import 'cover_art.dart';

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
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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
    this.height = 176,
    this.rows = 1,
    this.cardWidth = 118,
  });

  final List<Widget> children;
  final double height;
  final int rows;
  final double cardWidth;

  double _effectiveHeight(BuildContext context) {
    final textLines = MediaQuery.textScalerOf(context).scale(27) * 2;
    return height + (textLines - 54);
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
