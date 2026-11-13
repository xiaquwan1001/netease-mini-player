// 「一键匿名提交」的门槛: 端点未配置 / 开关未打开时不能发, 且整行禁用而不是静默失败。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_meta.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/settings_diagnostics_page.dart';

rust.InitInfo info() => rust.InitInfo(
  dataDir: '/tmp/minincm',
  deviceId: 'dev-1',
  loggedIn: false,
  vip: false,
  providers: const [],
);

Widget host() => MaterialApp(
  home: DiagnosticsPage(info: info(), ping: () async => 'pong'),
);

void main() {
  setUp(() {
    // 单例: 每个用例复位, 避免串状态
    AppSettings.instance.anonymousDebug = false;
  });

  testWidgets('端点未配置(kDiagUploadEndpoint 为空): 一键提交行禁用, 只留本地生成', (tester) async {
    expect(
      kDiagUploadEndpoint.trim(),
      isEmpty,
      reason: '测试前提: 仓库里默认不填端点(token/域名由部署者手动配置)',
    );
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('一键匿名提交'), findsOneWidget);
    expect(find.textContaining('作者还没配置接收端'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('一键匿名提交'), matching: find.byType(ListTile)),
    );
    expect(tile.enabled, isFalse, reason: '未配置端点时不能点');
    expect(find.text('生成匿名诊断包'), findsOneWidget);
  });

  testWidgets('开关默认关: 匿名诊断分组里能看到开关与两个动作', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('允许匿名发送 debug 数据'), findsOneWidget);
    final sw = tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('允许匿名发送 debug 数据'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(sw.value, isFalse);
    // 点开关直接落设置(偶数次回来, 避免影响其它用例)
    await tester.tap(find.text('允许匿名发送 debug 数据'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.anonymousDebug, isTrue);
    await tester.tap(find.text('允许匿名发送 debug 数据'));
    await tester.pumpAndSettle();
    expect(AppSettings.instance.anonymousDebug, isFalse);
  });
}
