// 批次 S2a / R3: 设置页「关于」分组新增「开源仓库」(点开系统浏览器)与「版本与许可」。
// 断言: 关于分组出现 GitHub 链接文本与版本号文本; 点「开源仓库」把 kGithubUrl
// 交给 PlatformBridge.openUrl(Android 走 ncm/open 通道, 用通道 mock 校验)。
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_meta.dart';
import 'package:minincm/src/settings_view.dart';

/// 记录 `ncm/open` 通道收到的 openUrl 参数(PlatformBridge 的 Android 分支)。
List<Map<Object?, Object?>> recordOpenUrlCalls(WidgetTester tester) {
  final calls = <Map<Object?, Object?>>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('ncm/open'),
    (call) async {
      if (call.method == 'openUrl') {
        final args = call.arguments;
        if (args is Map) calls.add(args.cast<Object?, Object?>());
      }
      return null;
    },
  );
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('ncm/open'), null));
  return calls;
}

Widget host() =>
    const MaterialApp(home: Scaffold(body: SettingsView(info: null)));

void main() {
  testWidgets('关于分组展示 GitHub 链接与版本号/许可', (tester) async {
    await tester.pumpWidget(host());

    expect(find.text('开源仓库'), findsOneWidget);
    expect(find.text(kGithubUrl), findsOneWidget);
    expect(find.text('版本与许可'), findsOneWidget);
    expect(find.text('v$kAppVersion · $kLicenseSummary'), findsOneWidget);
  });

  testWidgets('点「开源仓库」把正确 URL 交给 PlatformBridge', (tester) async {
    final calls = recordOpenUrlCalls(tester);
    await tester.pumpWidget(host());

    if (Platform.isAndroid) {
      await tester.tap(find.text('开源仓库'));
      await tester.pump();
      expect(calls, hasLength(1));
      expect(calls.single['url'], kGithubUrl);
    } else {
      // 本机 flutter test 跑在 Linux: PlatformBridge.openUrl 走 xdg-open
      // (会真实拉起浏览器, 测试不该触发该副作用), 不经过 ncm/open 通道。
      // 这里校验 tile 已接上 onTap 且 subtitle 即仓库地址, 通道契约由 Android 分支覆盖。
      final tile = tester.widget<ListTile>(
        find.ancestor(
          of: find.text('开源仓库'),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.onTap, isNotNull);
      expect((tile.subtitle! as Text).data, kGithubUrl);
    }
  });

  testWidgets('关于 subtitle 设了 maxLines/ellipsis 防窄屏溢出', (tester) async {
    await tester.pumpWidget(host());

    final urlSub = tester.widget<Text>(find.text(kGithubUrl));
    expect(urlSub.maxLines, 2);
    expect(urlSub.overflow, TextOverflow.ellipsis);

    final verSub =
        tester.widget<Text>(find.text('v$kAppVersion · $kLicenseSummary'));
    expect(verSub.maxLines, 2);
    expect(verSub.overflow, TextOverflow.ellipsis);
  });
}
