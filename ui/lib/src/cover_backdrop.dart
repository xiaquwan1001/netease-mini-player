/// 封面取色背景容器: 用两层渐变(深色底 → primary 低透明度柔化色)包住内容,
/// palette 切换时 300ms 平滑过渡。
///
/// - palette == null 或 palette.isFallback: 透明直通, 完全回退主题色, 不闪黑;
/// - 深色下渐变亮度上限见 cover_palette.dart 的 kMaxGradientLightness
///   (primary 与背景混合比例 ~8%~18%), 避免刺眼。
library;

import 'package:flutter/material.dart';

import 'cover_palette.dart';

class CoverBackdrop extends StatelessWidget {
  const CoverBackdrop({super.key, required this.palette, required this.child});

  final CoverPalette? palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final usePalette = p != null && !p.isFallback;
    final Decoration? decoration = usePalette
        ? BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: p.backgroundGradient,
            ),
          )
        : null; // 透明直通, 完全回退主题
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      decoration: decoration,
      child: child,
    );
  }
}
