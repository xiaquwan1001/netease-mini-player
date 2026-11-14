import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/theme.dart';

/// 回归: 设置页在「窄屏 + 大字号」下不得溢出。
///
/// 实测机型(vivo 真机): 1440x3168 物理分辨率, density override 768
/// ⇒ 逻辑宽 300dp; 系统字号 1.25(+ App 内「界面字号」最大 1.3 ⇒ 1.625)。
/// 旧实现把 SegmentedButton 放在 ListTile.trailing, 该组合下 ListTile 断言
/// "Trailing widget consumes the entire tile width" 并使后续 widget 不布局,
/// 表现为「主题模式」那档文字竖排、越界。
void main() {
  testWidgets('300dp + 各档字号: 设置页布局无异常且主题可切换', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(300, 1200);
    addTearDown(tester.view.reset);

    final settings = AppSettings.instance;
    final beforeMode = settings.themeMode;
    final beforeOled = settings.oledDark;
    addTearDown(
      () => settings.update(themeMode: beforeMode, oledDark: beforeOled),
    );
    // 固定起点: 跟随系统 + 纯黑关(测试环境的 platformBrightness 是浅色)
    settings.update(themeMode: ThemeMode.system, oledDark: false);

    for (final scale in <double>[1.0, 1.25, 1.3, 1.625]) {
      final errors = <FlutterErrorDetails>[];
      final previousOnError = FlutterError.onError;
      FlutterError.onError = errors.add;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: const Scaffold(body: SettingsView(info: null)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      FlutterError.onError = previousOnError;

      expect(
        errors,
        isEmpty,
        reason:
            'textScale=$scale 时布局应无异常: '
            '${errors.isEmpty ? '' : errors.first.exceptionAsString()}',
      );
      // 「主题模式」三档都在(2026-11 用户需求 1: 从四档拆回), 且都能点
      expect(find.text('跟随'), findsOneWidget);
      expect(find.text('浅色'), findsOneWidget);
      expect(find.text('深色'), findsOneWidget);

      // 三档横向排开: 同一行(y 相同), x 递增 ⇒ 不是竖排
      final follow = tester.getCenter(find.text('跟随'));
      final light = tester.getCenter(find.text('浅色'));
      final dark = tester.getCenter(find.text('深色'));
      expect(follow.dy, moreOrLessEquals(light.dy, epsilon: 1));
      expect(light.dy, moreOrLessEquals(dark.dy, epsilon: 1));
      expect(follow.dx, lessThan(light.dx));
      expect(light.dx, lessThan(dark.dx));

      // 分段控件三档在 300dp 下仍可能超宽, 但外层是横向可滚动的
      // SingleChildScrollView(不裁切、不溢出报错), 这里只断言高度不失控。
      final board = tester.getRect(find.byType(SegmentedButton<ThemeChoice>));
      expect(board.height, lessThan(64));
      // 默认字号下三档应整体放得下(不再需要横向滚动)
      if (scale == 1.0) expect(board.right, lessThanOrEqualTo(300));

      // 左边界要和同卡里的普通 ListTile 行对齐
      // (12dp ListView padding + 12dp 内容 padding = 24dp; 2026-11 布局审计把
      // ListTile 默认 16 收到 12, 与页面 12 叠后共 24),
      // 否则整行会被外层 Column 的居中挤成"缩进"的样子。
      double contentLeft = 12 + 12;
      expect(
        tester.getRect(find.text('主题模式')).left,
        moreOrLessEquals(contentLeft, epsilon: 0.5),
      );
      expect(board.left, moreOrLessEquals(contentLeft, epsilon: 0.5));
      // 「主题色」行(曾经的独立 tile)与同级 ListTile 左边界必须一致
      expect(
        tester.getRect(find.text('主题色')).left,
        moreOrLessEquals(contentLeft, epsilon: 0.5),
      );
      // 独立的「纯黑 (OLED)」开关: 同卡子项, 左边界对齐且不出屏
      final oledTitle = tester.getRect(find.text('纯黑 (OLED)'));
      expect(oledTitle.left, moreOrLessEquals(contentLeft, epsilon: 0.5));
      expect(oledTitle.right, lessThanOrEqualTo(300));
      // 浅色/跟随浅色下开关不生效: 副标题必须说明「仅在深色时生效」
      expect(find.textContaining('仅在深色时生效'), findsOneWidget);
    }

    // 跟随系统 + 纯黑可同时为真(四档时代的互斥 bug 回归)
    await tester.tap(find.text('纯黑 (OLED)'));
    await tester.pumpAndSettle();
    expect(settings.oledDark, isTrue);
    expect(settings.themeMode, ThemeMode.system);
    expect(themeChoiceOf(settings), ThemeChoice.system);

    // 切到深色不覆写纯黑开关
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
    expect(settings.oledDark, isTrue);
  });
}
