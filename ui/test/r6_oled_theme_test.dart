import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/theme.dart';

/// R6: 深色模式提供 OLED 纯黑.
///
/// 验收口径(docs/plan-2026-11-09-settings-and-player.md §5):
/// 深色 + OLED ⇒ Scaffold / NavigationBar / 播放条(Material canvas) 背景严格 #000000,
/// 关掉 ⇒ 回到 Material 默认深色(不是纯黑).
void main() {
  Future<void> pumpShell(
    WidgetTester tester, {
    required bool oled,
    bool narrow = false,
  }) async {
    if (narrow) {
      tester.view.physicalSize = const Size(300, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(oled: oled),
        themeMode: ThemeMode.dark,
        home: MediaQuery(
          data: MediaQueryData(
            textScaler: narrow
                ? const TextScaler.linear(1.25)
                : TextScaler.noScaling,
          ),
          child: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  // 播放条外壳: Material(elevation) 取 canvasColor
                  const Material(elevation: 8, child: SizedBox(height: 48)),
                  const Expanded(child: Card(child: SizedBox.expand())),
                ],
              ),
              bottomNavigationBar: NavigationBar(
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.search), label: '搜索'),
                  NavigationDestination(icon: Icon(Icons.person), label: '我的'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Color? scaffoldColor(WidgetTester tester) {
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    return scaffold.backgroundColor ?? theme.scaffoldBackgroundColor;
  }

  testWidgets('OLED 开: Scaffold/NavigationBar/播放条 都是纯黑 #000000', (
    tester,
  ) async {
    await pumpShell(tester, oled: true);

    expect(scaffoldColor(tester), kOledBlack);

    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final navTheme = Theme.of(tester.element(find.byType(NavigationBar)));
    expect(
      nav.backgroundColor ?? navTheme.navigationBarTheme.backgroundColor,
      kOledBlack,
    );

    // 播放条: Material(canvas) 缺省色 = canvasColor
    final bar = tester.widget<Material>(find.byType(Material).first);
    final barCtx = tester.element(find.byType(Material).first);
    expect(bar.color ?? Theme.of(barCtx).canvasColor, kOledBlack);

    // 卡片表面也是纯黑系(不允许回到 #121212)
    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    expect(scheme.surface, kOledBlack);
    expect(scheme.onSurface.computeLuminance(), greaterThan(0.6));
  });

  testWidgets('OLED 关: 保持 Material 默认深色(非纯黑)', (tester) async {
    await pumpShell(tester, oled: false);
    expect(scaffoldColor(tester), isNot(kOledBlack));
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor,
      isNot(kOledBlack),
    );
  });

  testWidgets('窄屏 300dp + 1.25 字号: 壳层不溢出且仍是 OLED 纯黑', (tester) async {
    await pumpShell(tester, oled: true, narrow: true);
    expect(tester.takeException(), isNull);
    expect(scaffoldColor(tester), kOledBlack);
    expect(find.text('搜索'), findsOneWidget);
  });

  test('OLED 只影响深色: 浅色主题底色不是纯黑', () {
    expect(buildLightTheme().scaffoldBackgroundColor, isNot(kOledBlack));
  });

  testWidgets('设置页: 三档 + 独立「纯黑 (OLED)」开关互不覆写且持久化', (tester) async {
    final settings = AppSettings.instance;
    final beforeMode = settings.themeMode;
    final beforeOled = settings.oledDark;
    addTearDown(
      () => settings.update(themeMode: beforeMode, oledDark: beforeOled),
    );
    settings.update(themeMode: ThemeMode.system, oledDark: false);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SettingsView(info: null))),
    );
    await tester.pumpAndSettle();

    // 2026-11 用户需求 1: 主题模式回到三档(跟随/浅色/深色), 纯黑是独立子项
    expect(find.text('纯黑'), findsNothing);
    expect(find.text('纯黑 (OLED)'), findsOneWidget);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
    expect(settings.oledDark, isFalse);

    await tester.tap(find.text('纯黑 (OLED)'));
    await tester.pumpAndSettle();
    expect(settings.oledDark, isTrue);
    expect(settings.themeMode, ThemeMode.dark);

    // 切回「跟随系统」不关掉纯黑 ⇒ 跟随 + 纯黑可同时为真
    await tester.tap(find.text('跟随'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.system);
    expect(settings.oledDark, isTrue);
    expect(themeChoiceOf(settings), ThemeChoice.system);
  });
}
