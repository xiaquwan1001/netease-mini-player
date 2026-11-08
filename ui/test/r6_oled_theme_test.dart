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
  Future<void> pumpShell(WidgetTester tester, {required bool oled}) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(oled: oled),
      themeMode: ThemeMode.dark,
      home: Builder(
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
    ));
    await tester.pumpAndSettle();
  }

  Color? scaffoldColor(WidgetTester tester) {
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final theme = Theme.of(tester.element(find.byType(Scaffold)));
    return scaffold.backgroundColor ?? theme.scaffoldBackgroundColor;
  }

  testWidgets('OLED 开: Scaffold/NavigationBar/播放条 都是纯黑 #000000', (tester) async {
    await pumpShell(tester, oled: true);

    expect(scaffoldColor(tester), kOledBlack);

    final nav = tester.widget<NavigationBar>(find.byType(NavigationBar));
    final navTheme = Theme.of(tester.element(find.byType(NavigationBar)));
    expect(nav.backgroundColor ?? navTheme.navigationBarTheme.backgroundColor, kOledBlack);

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
    expect(Theme.of(tester.element(find.byType(Scaffold))).scaffoldBackgroundColor,
        isNot(kOledBlack));
  });

  test('OLED 只影响深色: 浅色主题底色不是纯黑', () {
    expect(buildLightTheme().scaffoldBackgroundColor, isNot(kOledBlack));
  });

  testWidgets('设置页「OLED 纯黑」开关写回 AppSettings 并持久到 settings.json', (tester) async {
    final settings = AppSettings.instance;
    final before = settings.oledDark;
    addTearDown(() => settings.update(oledDark: before));

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: SettingsView(info: null)),
    ));
    await tester.pumpAndSettle();

    expect(find.text('OLED 纯黑'), findsOneWidget);
    await tester.tap(find.text('OLED 纯黑'));
    await tester.pumpAndSettle();
    expect(settings.oledDark, isTrue);
  });
}
