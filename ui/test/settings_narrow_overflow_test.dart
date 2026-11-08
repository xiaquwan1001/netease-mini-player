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
    final before = settings.themeMode;
    addTearDown(() => settings.update(themeMode: before));

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

      expect(errors, isEmpty,
          reason: 'textScale=$scale 时布局应无异常: '
              '${errors.isEmpty ? '' : errors.first.exceptionAsString()}');
      // 「主题模式」三段都在, 且都能点(不被挤成竖排/裁掉)
      expect(find.text('跟随'), findsOneWidget);
      expect(find.text('浅色'), findsOneWidget);
      expect(find.text('深色'), findsOneWidget);

      // 三段横向排开: 同一行(y 相同), x 递增 ⇒ 不是竖排
      final follow = tester.getCenter(find.text('跟随'));
      final light = tester.getCenter(find.text('浅色'));
      final dark = tester.getCenter(find.text('深色'));
      expect(follow.dy, moreOrLessEquals(light.dy, epsilon: 1));
      expect(light.dy, moreOrLessEquals(dark.dy, epsilon: 1));
      expect(follow.dx, lessThan(light.dx));
      expect(light.dx, lessThan(dark.dx));

      // 分段控件整体不超出卡片内容区(300dp - ListView 12*2 padding)
      final board = tester.getRect(find.byType(SegmentedButton<ThemeMode>));
      expect(board.right, lessThanOrEqualTo(300 - 12));
      expect(board.height, lessThan(64));

      // 左边界要和同卡里的普通 ListTile 行对齐
      // (12dp ListView padding + 16dp 内容 padding = 28dp),
      // 否则整行会被外层 Column 的居中挤成"缩进"的样子。
      double contentLeft = 12 + 16;
      expect(tester.getRect(find.text('主题模式')).left, moreOrLessEquals(contentLeft, epsilon: 0.5));
      expect(board.left, moreOrLessEquals(contentLeft, epsilon: 0.5));
      expect(tester.getRect(find.text('OLED 纯黑')).left, moreOrLessEquals(contentLeft, epsilon: 0.5));
    }

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(settings.themeMode, ThemeMode.dark);
  });
}
