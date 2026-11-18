import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/theme.dart';

/// 用户 2026-11-18 口径: 「对于安卓端, 通用的'关闭主窗口时'选项直接省略。」
///
/// Android 上整块不渲染(不是置灰、也不是留一行「仅 Linux 生效」的说明);
/// Windows 仍保留说明行(用户只点了 Android)。
///
/// 平台判定必须走纯谓词: `Platform.isAndroid` 在宿主机 widget 测试里恒为 false,
/// 没有真机就没法用 widget 测试造出 Android 平台。
void main() {
  test(
    'shouldShowCloseBehaviorTile: Linux=true / Android=false / Windows=true',
    () {
      // Linux: 真开关(直接退出 / 最小化到托盘)
      expect(
        shouldShowCloseBehaviorTile(isLinux: true, isAndroid: false),
        isTrue,
        reason: 'Linux 有真开关',
      );
      // Android: 整块省略
      expect(
        shouldShowCloseBehaviorTile(isLinux: false, isAndroid: true),
        isFalse,
        reason: 'Android 上「关闭主窗口时」整块不渲染',
      );
      // Windows: 保留「仅 Linux 生效」的说明行
      expect(
        shouldShowCloseBehaviorTile(isLinux: false, isAndroid: false),
        isTrue,
        reason: 'Windows 保留说明行',
      );
    },
  );

  testWidgets('宿主(非 Android)上这一块照常出现', (tester) async {
    tester.view.physicalSize = const Size(360, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLightTheme(),
        home: const Scaffold(body: SettingsView(info: null)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('关闭主窗口时'),
      findsOneWidget,
      reason: '宿主机是 Linux/Windows 口径, 这一块应该在',
    );
  });
}
