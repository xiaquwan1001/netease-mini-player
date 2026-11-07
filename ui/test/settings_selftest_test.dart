import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/settings_view.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

rust.InitInfo fakeInfo() => rust.InitInfo(
      dataDir: '/tmp/minincm',
      deviceId: 'dev-1',
      loggedIn: false,
      vip: false,
      providers: const [],
    );

/// 只覆盖 SettingsView 在测试里会碰到的方法, 其余走 noSuchMethod.
class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<String> crateApiPing({required String name}) async =>
      'pong from rust: $name';

  @override
  Future<List<rust.AccountDto>> crateApiAccounts() async => const [];
}

Finder tile() => find.byType(ChannelSelfCheckTile);

void main() {
  testWidgets('成功路径: 显示返回值与耗时', (tester) async {
    final gate = Completer<String>();
    await tester
        .pumpWidget(host(ChannelSelfCheckTile(ping: () => gate.future)));

    await tester.tap(tile());
    await tester.pump();
    expect(find.textContaining('正在自检'), findsOneWidget);

    gate.complete('pong:selftest');
    await tester.pumpAndSettle();
    expect(find.textContaining('通道正常'), findsOneWidget);
    expect(find.textContaining('pong:selftest'), findsOneWidget);
    expect(find.textContaining('ms'), findsOneWidget);
  });

  testWidgets('失败路径: 显示 friendlyError 文案且可再点重试', (tester) async {
    var calls = 0;
    Future<String> failOnce() async {
      calls++;
      if (calls == 1) throw Exception('boom');
      return 'pong:selftest';
    }

    await tester
        .pumpWidget(host(ChannelSelfCheckTile(ping: failOnce)));
    await tester.tap(tile());
    await tester.pumpAndSettle();
    expect(find.textContaining('通道异常'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);

    // 可重试: 再点一次变成成功
    await tester.tap(tile());
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.textContaining('通道正常'), findsOneWidget);
  });

  testWidgets('防重入: 连点两次只跑一次', (tester) async {
    var calls = 0;
    final gate = Completer<String>();
    await tester.pumpWidget(host(ChannelSelfCheckTile(ping: () {
      calls++;
      return gate.future;
    })));
    await tester.tap(tile());
    await tester.pump();
    expect(find.textContaining('正在自检'), findsOneWidget);
    // 第二次点击应被忽略
    await tester.tap(tile());
    await tester.pump();
    expect(calls, 1);
    gate.complete('pong:selftest');
    await tester.pumpAndSettle();
    expect(find.textContaining('通道正常'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.devicePixelRatio = 3.0;
    tester.view.physicalSize = const Size(900, 2100);
    tester.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearAllTestValues);

    final gate = Completer<String>();
    await tester
        .pumpWidget(host(ChannelSelfCheckTile(ping: () => gate.future)));
    await tester.tap(tile());
    await tester.pump();
    expect(tester.takeException(), isNull);

    gate.complete('pong:selftest');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('通道正常'), findsOneWidget);

    // 失败态文案也不溢出
    final gate2 = Completer<String>();
    await tester
        .pumpWidget(host(ChannelSelfCheckTile(ping: () => gate2.future)));
    await tester.tap(tile());
    await tester.pump();
    gate2.completeError(Exception('network unreachable after retries'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('不注入 ping 时 SettingsView 仍能正常 build', (tester) async {
    RustLib.initMock(api: _FakeRustApi());
    // 列表较长, 拉大视口让「诊断」节进入懒加载视窗
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(800, 2200);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host(SettingsView(
      info: fakeInfo(),
      isAndroid: false,
      onLogin: () {},
      onLogout: () async {},
      onShowAccounts: () {},
      onClearSearchHistory: () {},
    )));
    await tester.pump();
    expect(find.text('诊断'), findsOneWidget);
    expect(find.text('Rust 通道自检'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // 不点自检: 默认 rust.ping 需要真实通道, 这里只验证挂载与 build.
  });
}
