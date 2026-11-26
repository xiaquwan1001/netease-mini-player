import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;
import 'package:minincm/src/settings/settings_system_page.dart';

/// 审计 2026-11-26 P2#7: Android 13+ 拒绝通知权限后通知栏没有媒体卡片(无播放控制/进度/封面),
/// 改动前 App 里既没有原因提示也没有重开入口 —— 冷启动那次 `ensureNotificationPermission()`
/// 拒过之后再无出路。本页新增「通知权限」一行: 已开启只说一句, 被拒绝给直达系统设置的按钮。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 装假通道: [granted] 决定系统侧的权限态, [calls] 收原生方法名。
  List<String> installChannel({required bool granted}) {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationPermissionChannel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'notificationPermissionGranted':
              return granted;
            case 'openNotificationSettings':
              return true;
          }
          return null;
        });
    return calls;
  }

  tearDown(() {
    debugForceAndroid = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationPermissionChannel, null);
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SystemSettingsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('已开启: 只说已开启, 不给按钮', (tester) async {
    final calls = installChannel(granted: true);
    debugForceAndroid = true;
    await pumpPage(tester);

    expect(calls, contains('notificationPermissionGranted'));
    expect(find.byKey(const Key('notificationPermissionTile')), findsOneWidget);
    expect(find.textContaining('已开启'), findsOneWidget);
    expect(find.textContaining('被拒绝'), findsNothing);
    expect(find.byKey(const Key('openNotificationSettings')), findsNothing);
  });

  testWidgets('被拒绝: 说明原因 + 按钮跳系统通知设置页', (tester) async {
    final calls = installChannel(granted: false);
    debugForceAndroid = true;
    await pumpPage(tester);

    expect(find.byKey(const Key('notificationPermissionTile')), findsOneWidget);
    expect(find.textContaining('被拒绝'), findsOneWidget);
    expect(find.textContaining('通知栏不会显示播放控制'), findsOneWidget);

    final button = find.byKey(const Key('openNotificationSettings'));
    expect(button, findsOneWidget);
    expect(find.text('去系统设置'), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(calls, contains('openNotificationSettings'));
  });

  testWidgets('非 Android 不出现这一行(没有「通知被拒绝」这个状态)', (tester) async {
    installChannel(granted: false);
    expect(debugForceAndroid, isFalse, reason: '默认必须是关的');
    await pumpPage(tester);

    expect(find.byKey(const Key('notificationPermissionTile')), findsNothing);
    expect(find.text('通知权限'), findsNothing);
  });

  // 窄屏(300dp)+ 被拒绝态: 新增的这一行带按钮, 不能把列表挤溢出。
  testWidgets('300dp 窄屏下这一行不溢出', (tester) async {
    installChannel(granted: false);
    debugForceAndroid = true;
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SystemSettingsPage()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('notificationPermissionTile')), findsOneWidget);
  });

  // 查询失败(原生报错/通道不可用)一律按「没有权限」处理: 宁可让用户去系统设置看一眼,
  // 也不要谎报「已开启」把通知栏没播放控制这件事藏起来。
  testWidgets('查询报错按被拒绝处理, 不谎报已开启', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notificationPermissionChannel, (call) async {
          throw PlatformException(code: 'player_error', message: 'boom');
        });
    debugForceAndroid = true;
    await pumpPage(tester);

    expect(find.textContaining('被拒绝'), findsOneWidget);
    expect(find.byKey(const Key('openNotificationSettings')), findsOneWidget);
  });
}
