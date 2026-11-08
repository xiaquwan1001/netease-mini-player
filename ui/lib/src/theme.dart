import 'package:flutter/material.dart';

/// 品牌色(网易云红). 浅色/深色共用同一个 seed, 只换亮度 ⇒ 两套配色语义一致.
const Color kBrandSeed = Color(0xFFE60026);

/// OLED 纯黑(R6): 深色模式下用 #000000 取代 Material 默认的 #121212,
/// 在 OLED 屏上不发光的像素真正熄灭(省电 + 无灰边).
const Color kOledBlack = Color(0xFF000000);

/// 浅色主题(与改造前 ThemeData(colorSchemeSeed: kBrandSeed, useMaterial3: true) 等价)
ThemeData buildLightTheme() => ThemeData(
      colorSchemeSeed: kBrandSeed,
      useMaterial3: true,
    );

/// 深色主题. [oled] = true 时切到纯黑基底(R6), false 时保持 Material 默认深色.
///
/// 只改"底色/表面/导航栏/播放条(Material canvas)"这几层, 不动 M3 的 tonal 语义:
/// - colorScheme 的 surface 系列全部压成 #000000, 于是 Card/播放条/Dialog 底都是纯黑;
/// - onSurface 保持高对比(0xFFE6E6E6), 满足 M3 深色对比度要求;
/// - NavigationBar 用 navigationBarTheme.backgroundColor 覆盖(它不吃 surface 别名).
ThemeData buildDarkTheme({bool oled = false}) {
  final base = ThemeData(
    colorSchemeSeed: kBrandSeed,
    brightness: Brightness.dark,
    useMaterial3: true,
  );
  if (!oled) return base;

  const onSurface = Color(0xFFE6E6E6);
  final scheme = base.colorScheme.copyWith(
    surface: kOledBlack,
    onSurface: onSurface,
    surfaceContainerLowest: kOledBlack,
    surfaceContainerLow: kOledBlack,
    surfaceContainer: kOledBlack,
    surfaceContainerHigh: const Color(0xFF0C0C0C),
    surfaceContainerHighest: const Color(0xFF141414),
  );
  return base.copyWith(
    colorScheme: scheme,
    // Material(type: canvas) 的缺省底色(播放条外壳走这条)
    canvasColor: kOledBlack,
    scaffoldBackgroundColor: kOledBlack,
    dialogTheme: base.dialogTheme.copyWith(backgroundColor: scheme.surfaceContainerHigh),
    bottomSheetTheme: base.bottomSheetTheme.copyWith(
      backgroundColor: scheme.surfaceContainerHigh,
      surfaceTintColor: Colors.transparent,
    ),
    navigationBarTheme: base.navigationBarTheme.copyWith(
      backgroundColor: kOledBlack,
      surfaceTintColor: Colors.transparent,
    ),
    appBarTheme: base.appBarTheme.copyWith(
      backgroundColor: kOledBlack,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
