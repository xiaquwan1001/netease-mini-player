// 视觉风格(主题色)切换: 绿/蓝/橘/粉 四色 + 默认网易云红, 每个色板都同时管浅色与深色.
//
// 口径:
// - 色板只是 colorSchemeSeed, 浅色/深色是同一 seed 的两种亮度 ⇒ "每个颜色都有深色/浅色"
//   由「主题模式」+「色板」两个正交开关组合出来, 不是 5x2 的独立配置;
// - 默认色板必须与改造前完全一致(kBrandSeed);
// - 未知/损坏的配置回落默认, 不能让界面没主题。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/theme.dart';

void main() {
  test('五个色板: 浅色/深色各自的 primary 都不同, 且深色仍是 dark', () {
    final lightPrimaries = <Color>{};
    final darkPrimaries = <Color>{};
    for (final palette in AccentPalette.values) {
      final light = buildLightTheme(accent: palette);
      final dark = buildDarkTheme(accent: palette);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      lightPrimaries.add(light.colorScheme.primary);
      darkPrimaries.add(dark.colorScheme.primary);
    }
    expect(AccentPalette.values.length, 5);
    expect(
      lightPrimaries.length,
      AccentPalette.values.length,
      reason: '每个色板的浅色主题必须是不同配色',
    );
    expect(
      darkPrimaries.length,
      AccentPalette.values.length,
      reason: '每个色板的深色主题必须是不同配色',
    );
  });

  test('红色要够"红": 高彩度 + 与樱粉的色相拉开(用户实测反馈的回归)', () {
    final red = HSLColor.fromColor(buildLightTheme().colorScheme.primary);
    final pink = HSLColor.fromColor(
      buildLightTheme(accent: AccentPalette.pink).colorScheme.primary,
    );
    // 旧实现(tonalSpot + 0xFFE60026)的 primary 是 #904A46: 饱和度约 28%,
    // 与樱粉 #8E4958 视觉上几乎一致 —— 这里把口径固定下来。
    expect(red.saturation, greaterThan(0.85), reason: '品牌红必须高彩度(不能是灰玫瑰)');
    expect(red.hue, lessThan(15.0), reason: '品牌红应落在正红区(0 度附近)');
    expect(pink.saturation, greaterThan(0.85), reason: '樱粉也要有彩度');
    expect(pink.hue, greaterThan(300.0), reason: '樱粉落在洋红一侧');
    final gap = (pink.hue - red.hue).abs();
    expect(gap, greaterThan(25.0), reason: '红与粉的色相差要够大, 否则用户分不出来(旧实现只有约 7 度)');
  });

  test('默认色板 = 改造前的品牌红(不传 accent 与传 neteaseRed 等价)', () {
    expect(AccentPalette.neteaseRed.seed, kBrandSeed);
    expect(
      buildLightTheme().colorScheme.primary,
      buildLightTheme(accent: AccentPalette.neteaseRed).colorScheme.primary,
    );
    expect(
      buildDarkTheme().colorScheme.primary,
      buildDarkTheme(accent: AccentPalette.neteaseRed).colorScheme.primary,
    );
  });

  test('OLED 纯黑与色板正交: 非红主题色下底色仍严格 #000000', () {
    final theme = buildDarkTheme(oled: true, accent: AccentPalette.blue);
    expect(theme.scaffoldBackgroundColor, kOledBlack);
    expect(theme.canvasColor, kOledBlack);
    expect(theme.colorScheme.surface, kOledBlack);
    // 主色仍来自所选色板(没被 OLDE 覆盖)
    expect(
      theme.colorScheme.primary,
      buildDarkTheme(accent: AccentPalette.blue).colorScheme.primary,
    );
  });

  test('AccentPalette.fromId: 已知 id 往返, 未知/空回落默认', () {
    for (final palette in AccentPalette.values) {
      expect(AccentPalette.fromId(palette.id), palette);
    }
    expect(AccentPalette.fromId(null), AccentPalette.neteaseRed);
    expect(AccentPalette.fromId(''), AccentPalette.neteaseRed);
    expect(AccentPalette.fromId('neon-purple'), AccentPalette.neteaseRed);
  });

  testWidgets('设置页点色点即切换主题色(并写回设置)', (tester) async {
    final settings = AppSettings.instance;
    final before = settings.accent;
    addTearDown(() => settings.update(accent: before));
    await settings.update(accent: AccentPalette.neteaseRed);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsView(info: null))),
    );
    await tester.pumpAndSettle();

    // 五个色点都在(键名 = accent-<id>)
    for (final palette in AccentPalette.values) {
      expect(find.byKey(ValueKey('accent-${palette.id}')), findsOneWidget);
    }
    expect(find.text('网易云红 · 浅色/深色通用'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('accent-green')));
    await tester.pumpAndSettle();
    expect(settings.accent, AccentPalette.green);
    expect(find.text('森林绿 · 浅色/深色通用'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: '选中项带对勾');
  });

  testWidgets('300dp + 1.625 字号: 主题色选择器不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.625)),
          child: const Scaffold(body: SettingsView(info: null)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('主题色'), findsOneWidget);
  });

  // 落盘往返放最后: 它会把单例的 settings 文件指到临时目录(测完即删),
  // 放在前面会让同文件后续用例的 update() 去写一个已删除的路径。
  test('设置落盘往返: accent 写进 settings.json, 重启后读回同一个色板', () async {
    final dir = await Directory.systemTemp.createTemp('ncm-accent');
    addTearDown(() => dir.delete(recursive: true));
    final settings = AppSettings.instance;
    final before = settings.accent;
    addTearDown(() => settings.update(accent: before));

    await settings.load(dir.path);
    await settings.update(accent: AccentPalette.orange);
    final raw = jsonDecode(
      await File('${dir.path}/settings.json').readAsString(),
    );
    expect(raw['accent'], 'orange');

    // 模拟重启: 用同一份目录重新 load
    settings.accent = AccentPalette.neteaseRed;
    await settings.load(dir.path);
    expect(settings.accent, AccentPalette.orange);
  });
}
