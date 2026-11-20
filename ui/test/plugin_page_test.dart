// 插件管理页(设置 → 关于 → 插件)的四态 / 启停 / 重扫 / 平台不支持。
//
// 取数全靠 `RustLib.initMock` 注入的替身(每个测试文件一个进程, initMock 只能调一次),
// 所以这里不碰真 FFI、不联网。页面本身不做任何业务判断(全部在 Rust 侧), 测试锁的是
// UI 契约: 「四态走 AsyncView」「总开关二次确认 + 风险文案」「重扫期间不可重复点」
// 「宿主未启用 / 条目坏 ⇒ 单插件开关禁用」「Android 只解释不支持、不暴露写入口」。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/settings_plugins_page.dart';

/// 可变的替身状态: 每个用例自己摆好"磁盘上的样子"。
class _FakePluginHost implements RustLibApi {
  bool supported = true;
  bool enabled = false;
  bool active = false;
  String root = '/home/u/.local/share/minincm/plugins';
  String? error;
  List<rust.PluginSummaryDto> summaries = const [];
  List<rust.PluginFailureDto> failures = const [];
  List<rust.PluginRejectedDto> rejected = const [];

  /// 写调用记录(断言"点了才调、且只调一次")。
  final List<String> calls = [];

  /// 重扫闸门: 非 null 时 pluginRescan 停在这里(测 loading 态)。
  Completer<void>? rescanGate;

  /// 首屏读状态失败注入(测 AsyncView 的错误态 + 重试)。
  Object? statusError;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<rust.PluginStatusDto> crateApiPluginPluginStatus() async {
    final err = statusError;
    if (err != null) {
      statusError = null;
      throw err;
    }
    return rust.PluginStatusDto(
      supported: supported,
      enabled: enabled,
      active: active,
      root: root,
      error: error,
      loaded: summaries
          .where((s) => s.enabled && s.error == null)
          .map((s) => s.id)
          .toList(),
      failed: failures.length,
    );
  }

  @override
  Future<List<rust.PluginSummaryDto>> crateApiPluginPluginSummaries() async =>
      summaries;

  @override
  Future<List<rust.PluginFailureDto>> crateApiPluginPluginFailures() async =>
      failures;

  @override
  Future<List<rust.PluginRejectedDto>> crateApiPluginPluginRejected() async =>
      rejected;

  @override
  Future<void> crateApiPluginPluginSetEnabled({required bool enabled}) async {
    calls.add('setEnabled($enabled)');
    if (!supported) {
      throw const rust.FfiError(
        kind: 'unsupported',
        retryable: false,
        detail: 'set_enabled: 当前平台不带插件宿主',
      );
    }
    this.enabled = enabled;
    active = enabled;
  }

  @override
  Future<void> crateApiPluginPluginEnable({required String id}) async {
    calls.add('enable($id)');
    if (!enabled) {
      throw const rust.FfiError(
        kind: 'forbidden',
        retryable: false,
        detail: '插件宿主未启用',
      );
    }
    summaries = [
      for (final s in summaries)
        if (s.id == id)
          rust.PluginSummaryDto(
            id: s.id,
            name: s.name,
            version: s.version,
            enabled: true,
            requestDomains: s.requestDomains,
          )
        else
          s,
    ];
  }

  @override
  Future<void> crateApiPluginPluginDisable({required String id}) async {
    calls.add('disable($id)');
    summaries = [
      for (final s in summaries)
        if (s.id == id)
          rust.PluginSummaryDto(
            id: s.id,
            name: s.name,
            version: s.version,
            enabled: false,
            requestDomains: s.requestDomains,
          )
        else
          s,
    ];
  }

  @override
  Future<rust.PluginRescanDto> crateApiPluginPluginRescan() async {
    calls.add('rescan');
    final gate = rescanGate;
    if (gate != null) await gate.future;
    return rust.PluginRescanDto(
      scanned: const ['demo'],
      loaded: const ['demo'],
      skipped: const [],
      failed: const [],
    );
  }
}

rust.PluginSummaryDto _summary(
  String id, {
  String? name,
  bool enabled = false,
  List<String> domains = const [],
  String? error,
}) => rust.PluginSummaryDto(
  id: id,
  name: name ?? id,
  version: '1.0.0',
  enabled: enabled,
  requestDomains: domains,
  error: error,
);

final _fake = _FakePluginHost();

Widget _host() => const MaterialApp(home: PluginsPage());

/// 等首屏的四份读视图落地(0 网络, 一次 pump 两帧够)。
Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _fake));

  setUp(() {
    _fake
      ..supported = true
      ..enabled = false
      ..active = false
      ..root = '/home/u/.local/share/minincm/plugins'
      ..error = null
      ..summaries = const []
      ..failures = const []
      ..rejected = const []
      ..statusError = null
      ..rescanGate = null;
    _fake.calls.clear();
  });

  testWidgets('Android(supported=false): 只解释不支持, 没有总开关也没有列表', (tester) async {
    _fake
      ..supported = false
      ..error = 'unsupported: 当前平台不带插件宿主';
    await _pumpPage(tester);

    expect(find.text('当前平台不支持插件'), findsOneWidget);
    expect(find.textContaining('当前平台不带插件宿主'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    expect(find.text('重扫'), findsNothing);
  });

  testWidgets('总开关关闭: 给"为什么是空的"的解释, 单插件开关全禁用', (tester) async {
    _fake.summaries = [
      _summary('demo', name: '示例插件', domains: const ['music.example.com']),
    ];
    await _pumpPage(tester);

    expect(find.textContaining('总开关未打开'), findsOneWidget);
    // 宿主未启用 ⇒ 单插件开关不可切(否则点下去只会拿到 forbidden)。
    expect(tester.widget<SwitchListTile>(_pluginTile('示例插件')).onChanged, isNull);
    expect(find.textContaining('出站: music.example.com'), findsOneWidget);
  });

  testWidgets('总开关打开: 列出插件 + 失败与被拒收分区 + 坏条目不可切', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..summaries = [
        _summary('demo', name: '示例插件', enabled: true, domains: const ['a.com']),
        _summary('broken', name: '坏插件', error: '清单缺少 id'),
      ]
      ..failures = const [
        rust.PluginFailureDto(id: 'broken2', detail: 'manifest.json 解析失败'),
      ]
      ..rejected = const [
        rust.PluginRejectedDto(entry: 'dup', detail: '跨目录同 id'),
      ];
    await _pumpPage(tester);

    expect(find.text('示例插件'), findsOneWidget);
    expect(find.text('坏插件'), findsOneWidget);
    expect(find.text('Failed'), findsNothing);
    expect(find.text('失败'), findsOneWidget);
    expect(find.text('broken2'), findsOneWidget);
    expect(find.textContaining('manifest.json 解析失败'), findsOneWidget);
    expect(find.text('被拒收'), findsOneWidget);
    expect(find.textContaining('跨目录同 id'), findsOneWidget);
    // 坏条目(error != null)不能"启用": Rust 侧根本没登记它。
    expect(tester.widget<SwitchListTile>(_pluginTile('坏插件')).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(_pluginTile('示例插件')).onChanged, isNotNull);
    expect(find.textContaining('已装载 1 个'), findsOneWidget);
  });

  testWidgets('单插件停用: 调 disable 后重新取数, 开关跟着落下去', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..summaries = [_summary('demo', name: '示例插件', enabled: true)];
    await _pumpPage(tester);

    await tester.tap(_pluginTile('示例插件'));
    await tester.pumpAndSettle();

    expect(_fake.calls, ['disable(demo)']);
    expect(tester.widget<SwitchListTile>(_pluginTile('示例插件')).value, isFalse);
    expect(find.textContaining('已停用 demo'), findsOneWidget);
  });

  testWidgets('总开关: 二次确认(带风险文案), 取消不调 FFI, 确认才落盘', (tester) async {
    await _pumpPage(tester);

    await tester.tap(_masterTile());
    await tester.pumpAndSettle();
    expect(find.text('打开插件宿主?'), findsOneWidget);
    expect(find.textContaining('会真的执行它们'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_fake.calls, isEmpty);

    await tester.tap(_masterTile());
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(_fake.calls, ['setEnabled(true)']);
    expect(tester.widget<SwitchListTile>(_masterTile()).value, isTrue);
    expect(find.text('插件宿主已打开'), findsOneWidget);
  });

  testWidgets('重扫: 在飞时换行内 spinner 且按钮消失(不可重复点)', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..rescanGate = Completer<void>();
    await _pumpPage(tester);

    await tester.tap(find.text('重扫'));
    await tester.pump();

    expect(_fake.calls, ['rescan']);
    expect(find.text('重扫'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 总开关在飞期间也禁用(共用 Core 的唯一一把锁)。
    expect(tester.widget<SwitchListTile>(_masterTile()).onChanged, isNull);

    _fake.rescanGate!.complete();
    await tester.pumpAndSettle();

    expect(_fake.calls, ['rescan']); // 没有第二次
    expect(find.text('重扫'), findsOneWidget);
    expect(find.textContaining('重扫完成: 装载 1'), findsOneWidget);
  });

  testWidgets('写操作失败: 用 friendlyError 的 detail 提示, 页面回到可用态', (tester) async {
    // 宿主未启用时点单插件开关 —— 本页会禁用入口, 所以这里直接构造"Rust 侧报 forbidden"。
    _fake
      ..enabled = true
      ..active = true
      ..summaries = [_summary('demo', name: '示例插件')];
    await _pumpPage(tester);

    _fake.enabled = false; // 页面不知道, 模拟被其它出口关掉
    await tester.tap(_pluginTile('示例插件'));
    await tester.pumpAndSettle();

    expect(find.textContaining('插件宿主未启用'), findsOneWidget);
    // 失败不换 future ⇒ 内容还在, 没闪成错误态。
    expect(find.text('示例插件'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(_masterTile()).onChanged, isNotNull);
  });

  testWidgets('首屏失败: AsyncView 的错误态 + 重试能恢复', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..summaries = [_summary('demo', name: '示例插件')]
      ..statusError = Exception('core busy');
    await _pumpPage(tester);

    expect(find.textContaining('core busy'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.text('示例插件'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
  });
}

/// 总开关那一行。
Finder _masterTile() => find.widgetWithText(SwitchListTile, '启用插件宿主');

/// 某个插件名对应的开关行。
Finder _pluginTile(String name) => find.ancestor(
  of: find.text(name),
  matching: find.byType(SwitchListTile),
);
