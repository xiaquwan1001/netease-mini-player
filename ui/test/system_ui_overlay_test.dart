import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart' show MiniNcmApp;
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/system_ui_overlay.dart';

/// 审计 2026-11-26 P1#2: 状态栏 / 手势条的图标明暗要跟 **App 主题**走, 不是跟系统深浅色。
///
/// 基线(改动前)全仓 `SystemUiOverlayStyle` 0 命中 ⇒ 图标明暗只由 Android 主题 XML(启动窗口,
/// 跟系统)与 AppBar 自算的 AnnotatedRegion 决定; 而首页 5 个 tab 里 4 个没有 AppBar,
/// 于是"系统浅色 + App 深色"停在推荐页时黑图标压深底, 且一直不恢复。
void main() {
  const key = Key('body');

  Future<void> pumpThemed(WidgetTester tester, ThemeData theme) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (context, child) =>
            SystemUiOverlay(child: child ?? const SizedBox.shrink()),
        home: const Scaffold(body: SizedBox.expand(key: key)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 取树里那份根 AnnotatedRegion 的样式(AppBar 的样式会另有一份, 这里明确只要根的那份
  /// 必须是 SystemUiOverlay 装的)。
  SystemUiOverlayStyle overlayStyle(WidgetTester tester) {
    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
      find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first,
    );
    return region.value;
  }

  testWidgets('深色主题 → 浅色系统栏图标 + 三块颜色全透明', (tester) async {
    await pumpThemed(
      tester,
      ThemeData(brightness: Brightness.dark, useMaterial3: true),
    );
    final style = overlayStyle(tester);
    expect(style.statusBarIconBrightness, Brightness.light);
    expect(style.systemNavigationBarIconBrightness, Brightness.light);
    expect(style.statusBarBrightness, Brightness.dark);
    expect(style.statusBarColor, Colors.transparent);
    expect(style.systemNavigationBarColor, Colors.transparent);
    expect(style.systemNavigationBarDividerColor, Colors.transparent);
  });

  testWidgets('浅色主题 → 深色系统栏图标', (tester) async {
    await pumpThemed(
      tester,
      ThemeData(brightness: Brightness.light, useMaterial3: true),
    );
    final style = overlayStyle(tester);
    expect(style.statusBarIconBrightness, Brightness.dark);
    expect(style.systemNavigationBarIconBrightness, Brightness.dark);
    expect(style.statusBarBrightness, Brightness.light);
    expect(style.statusBarColor, Colors.transparent);
  });

  testWidgets('主题切换(同一棵树)后图标明暗跟着变', (tester) async {
    await pumpThemed(
      tester,
      ThemeData(brightness: Brightness.light, useMaterial3: true),
    );
    expect(overlayStyle(tester).statusBarIconBrightness, Brightness.dark);
    await pumpThemed(
      tester,
      ThemeData(brightness: Brightness.dark, useMaterial3: true),
    );
    expect(overlayStyle(tester).statusBarIconBrightness, Brightness.light);
  });

  // 壳层必须真的挂上: 只写个 widget 不接进 MaterialApp.builder 就等于没修。
  testWidgets('真壳(MiniNcmApp)挂的是 App 主题的明暗, 与系统深浅色无关', (tester) async {
    final settings = AppSettings.instance;
    final original = settings.themeMode;
    settings.themeMode = ThemeMode.dark;
    addTearDown(() {
      settings.themeMode = original;
    });
    // 系统仍是浅色: 图标必须是浅色(深色 App 的前景), 否则就是本 bug 的症状
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    // 真壳会起 bootstrap 轮询 Timer ⇒ 只 pump 固定帧数, 不用 pumpAndSettle
    await tester.pumpWidget(const MiniNcmApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    final styles = tester
        .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .map((region) => region.value)
        .toList();
    expect(
      styles.any(
        (style) =>
            style.statusBarIconBrightness == Brightness.light &&
            style.systemNavigationBarIconBrightness == Brightness.light,
      ),
      isTrue,
      reason: '深色 App + 浅色系统: 根 AnnotatedRegion 必须给浅色系统栏图标',
    );
  });
}
