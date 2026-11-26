// 桌面(Linux/Windows)页转场: 从框架默认的 Zoom 换成 Material 3 FadeForwards, 时长 220ms.
//
// 口径(车道 A, 父代理用 Xvfb+ffmpeg 逐帧复现):
// - 默认表给 linux/windows 的是 ZoomPageTransitionsBuilder —— 推入新页时旧页原地滞留并缩放,
//   全程不淡出, 用户读成「一级页没有过渡消失到二级, 闪一下」;
// - FadeForwards 才是「旧页 0~25% 淡出 + 左移 25%, 新页淡入 + 右移」, 时长收到 220ms;
// - 其余平台(android/iOS/macOS)必须保持框架默认表, 本改造只动桌面两项。

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/theme.dart';

/// 页子树外层所有 [FadeTransition] 里最小的 opacity —— 旧页的淡出/新页的淡入都由它驱动.
/// Zoom 下旧页只有缩放(快照 + opacity 恒 1.0), 这里要么找不到可变的 FadeTransition,
/// 要么最小值是 1.0 ⇒ 本断言直接区分改造前后.
double _minFadeOpacity(WidgetTester tester, Key pageKey) {
  final Iterable<FadeTransition> fades = tester.widgetList<FadeTransition>(
    find.ancestor(
      of: find.byKey(pageKey),
      matching: find.byType(FadeTransition),
    ),
  );
  expect(fades, isNotEmpty, reason: '页面应由 FadeTransition 包着');
  return fades
      .map((FadeTransition fade) => fade.opacity.value)
      .reduce((double a, double b) => a < b ? a : b);
}

void main() {
  test('linux/windows 走 FadeForwards(220ms), 其余平台保持框架默认表', () {
    final Map<TargetPlatform, PageTransitionsBuilder> builders =
        buildPageTransitionsTheme().builders;
    final Map<TargetPlatform, PageTransitionsBuilder> defaults =
        const PageTransitionsTheme().builders;

    expect(
      builders[TargetPlatform.linux],
      isA<DesktopFadeForwardsTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.windows],
      isA<DesktopFadeForwardsTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.linux],
      isA<FadeForwardsPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.windows],
      isA<FadeForwardsPageTransitionsBuilder>(),
    );

    // 220ms: 框架默认 450ms 是 Pixel/Android 16 手感, 桌面鼠标点击节奏更快
    expect(
      builders[TargetPlatform.linux]!.transitionDuration,
      const Duration(milliseconds: 220),
    );
    expect(
      builders[TargetPlatform.windows]!.transitionDuration,
      const Duration(milliseconds: 220),
    );

    // 其余平台一个都不能被顺手改掉(不手抄默认值, 直接比框架默认表)
    expect(
      builders[TargetPlatform.android],
      isA<PredictiveBackPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.iOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(
      builders[TargetPlatform.macOS],
      isA<CupertinoPageTransitionsBuilder>(),
    );
    expect(builders.keys.toSet(), defaults.keys.toSet(), reason: '平台集合不能多也不能少');
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
      TargetPlatform.macOS,
    ]) {
      expect(
        builders[platform],
        same(defaults[platform]),
        reason: '$platform 必须是框架默认 builder',
      );
    }
  });

  test('浅色/深色/深色 OLED 三个主题都挂上桌面转场表', () {
    for (final ThemeData theme in <ThemeData>[
      buildLightTheme(),
      buildDarkTheme(),
      buildDarkTheme(oled: true),
    ]) {
      final Map<TargetPlatform, PageTransitionsBuilder> builders =
          theme.pageTransitionsTheme.builders;
      expect(
        builders[TargetPlatform.linux],
        isA<DesktopFadeForwardsTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.windows],
        isA<DesktopFadeForwardsTransitionsBuilder>(),
      );
      expect(
        builders[TargetPlatform.android],
        isA<PredictiveBackPageTransitionsBuilder>(),
      );
    }
  });

  testWidgets('Linux 推页: 旧页在转场前段真的被 FadeTransition 淡出, 最终到达新页', (
    WidgetTester tester,
  ) async {
    // `flutter test` 下 FLUTTER_TEST 会把 defaultTargetPlatform 钉成 android(与宿主无关),
    // 所以用 ThemeData.platform 声明「这台是 linux 桌面」(转场表仍由 buildLightTheme 提供)
    final ThemeData linuxTheme = buildLightTheme().copyWith(
      platform: TargetPlatform.linux,
    );
    expect(linuxTheme.platform, TargetPlatform.linux);

    const oldPageKey = Key('desktop-transition-old-page');
    const newPageKey = Key('desktop-transition-new-page');
    final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: linuxTheme,
        home: const Scaffold(key: oldPageKey, body: SizedBox.expand()),
      ),
    );
    // 静止时旧页完全不透明
    expect(_minFadeOpacity(tester, oldPageKey), 1.0);

    final MaterialPageRoute<void> route = MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          const Scaffold(key: newPageKey, body: SizedBox.expand()),
    );
    navigatorKey.currentState!.push(route);
    await tester.pump();

    // 路由确实取到桌面 builder 的 220ms(而不是框架默认 450ms)
    expect(route.transitionDuration, const Duration(milliseconds: 220));

    // 20ms ≈ 转场 9%: 旧页 opacity 严格落在 (0,1), 即「正在淡出」而不是原地不动/瞬间消失
    await tester.pump(const Duration(milliseconds: 20));
    final double early = _minFadeOpacity(tester, oldPageKey);
    expect(early, lessThan(1.0));
    expect(early, greaterThan(0.0));

    // 60ms ≈ 转场 27%: 已过 FadeForwards 的 0~25% 淡出区间, 旧页基本消失(不再滞留)
    await tester.pump(const Duration(milliseconds: 40));
    final double late = _minFadeOpacity(tester, oldPageKey);
    expect(late, lessThan(1.0));
    expect(late, lessThanOrEqualTo(early));
    expect(late, lessThan(0.05));

    // 新页同时在淡入(不是硬切)
    expect(_minFadeOpacity(tester, newPageKey), lessThan(1.0));

    await tester.pumpAndSettle();
    expect(find.byKey(newPageKey), findsOneWidget);
    expect(find.byKey(oldPageKey), findsNothing);
    expect(_minFadeOpacity(tester, newPageKey), 1.0);
  });
}
