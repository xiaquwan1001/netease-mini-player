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

  /// 路由偏好(`auto` / `builtin` / `plugin:<id>`), 与 Rust 侧 `plugin_route.json` 同形。
  String routeMode = 'auto';

  /// 日志批次队列: 每次拉取弹一批(模拟 Rust 侧的取走语义)。
  List<List<rust.PluginLogDto>> logBatches = [];

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
            sources: s.sources,
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
            sources: s.sources,
          )
        else
          s,
    ];
  }

  @override
  Future<rust.PluginRescanDto> crateApiPluginPluginInstallScript({
    required String id,
    required String name,
    required String version,
    required String source,
    required List<String> lxEvents,
    required List<String> requestDomains,
  }) async {
    calls.add(
      'install($id|$name|$version|${lxEvents.join('+')}|${requestDomains.join('+')})',
    );
    if (!enabled) {
      throw const rust.FfiError(
        kind: 'forbidden',
        retryable: false,
        detail: '插件宿主未启用',
      );
    }
    summaries = [...summaries, _summary(id, name: name, sources: const [])];
    return rust.PluginRescanDto(
      scanned: [id],
      loaded: const [],
      skipped: [id],
      failed: const [],
    );
  }

  @override
  Future<rust.PluginRescanDto> crateApiPluginPluginInstallFile({
    required String id,
    required String name,
    required String version,
    required String path,
    required List<String> lxEvents,
    required List<String> requestDomains,
  }) async {
    calls.add('installFile($id|$name|$version|$path)');
    if (!enabled) {
      throw const rust.FfiError(
        kind: 'forbidden',
        retryable: false,
        detail: '插件宿主未启用',
      );
    }
    summaries = [...summaries, _summary(id, name: name, sources: const [])];
    return rust.PluginRescanDto(
      scanned: [id],
      loaded: const [],
      skipped: [id],
      failed: const [],
    );
  }

  @override
  Future<rust.PluginRescanDto> crateApiPluginPluginInstallUrl({
    required String id,
    required String name,
    required String version,
    required String url,
    required List<String> lxEvents,
    required List<String> requestDomains,
  }) async {
    calls.add('installUrl($id|$name|$version|$url)');
    if (!enabled) {
      throw const rust.FfiError(
        kind: 'forbidden',
        retryable: false,
        detail: '插件宿主未启用',
      );
    }
    if (!url.startsWith('https://')) {
      throw const rust.FfiError(
        kind: 'forbidden',
        retryable: false,
        detail: '只接受 https:// 开头的插件来源',
      );
    }
    summaries = [...summaries, _summary(id, name: name, sources: const [])];
    return rust.PluginRescanDto(
      scanned: [id],
      loaded: const [],
      skipped: [id],
      failed: const [],
    );
  }

  @override
  Future<rust.PluginRescanDto> crateApiPluginPluginUninstall({
    required String id,
  }) async {
    calls.add('uninstall($id)');
    if (!enabled) {
      throw const rust.FfiError(
        kind: 'forbidden',
        retryable: false,
        detail: '插件宿主未启用',
      );
    }
    if (!summaries.any((s) => s.id == id)) {
      throw const rust.FfiError(
        kind: 'notFound',
        retryable: false,
        detail: '插件未登记',
      );
    }
    summaries = _summariesWithout(id);
    // Rust 侧: 指向被卸载 id 的路由选择回 auto。
    if (routeMode == 'plugin:$id') routeMode = 'auto';
    return const rust.PluginRescanDto(
      scanned: [],
      loaded: [],
      skipped: [],
      failed: [],
    );
  }

  /// 卸载后的替身列表(去掉该 id)。
  List<rust.PluginSummaryDto> _summariesWithout(String id) => [
    for (final s in summaries)
      if (s.id != id) s,
  ];

  @override
  Future<List<rust.PluginLogDto>> crateApiPluginPluginLogs() async {
    calls.add('logs');
    return logBatches.isEmpty ? const [] : logBatches.removeAt(0);
  }

  @override
  Future<rust.PluginRouteModeDto> crateApiPluginPluginRouteMode() async {
    final mode = routeMode;
    return rust.PluginRouteModeDto(
      supported: supported,
      mode: mode,
      pluginId: mode.startsWith('plugin:') ? mode.substring(7) : null,
    );
  }

  @override
  Future<rust.PluginRouteModeDto> crateApiPluginPluginSetRouteMode({
    required String mode,
  }) async {
    calls.add('setRouteMode($mode)');
    if (!supported) {
      throw const rust.FfiError(
        kind: 'unsupported',
        retryable: false,
        detail: 'set_route_mode: 当前平台不带插件宿主',
      );
    }
    routeMode = mode.isEmpty ? 'auto' : mode;
    return crateApiPluginPluginRouteMode();
  }

  @override
  Future<rust.PluginRoutePlanDto> crateApiPluginPluginRoutePlan({
    required String cap,
  }) async {
    if (!supported) {
      return const rust.PluginRoutePlanDto(
        supported: false,
        target: 'builtin',
        reason: 'unsupported',
        detail: '当前平台不带插件宿主',
      );
    }
    if (!enabled) {
      return const rust.PluginRoutePlanDto(
        supported: true,
        target: 'builtin',
        reason: 'hostInactive',
        detail: '插件宿主未启用, 一律回内置',
      );
    }
    return rust.PluginRoutePlanDto(
      supported: true,
      target: routeMode,
      reason: 'selected',
      detail: '$cap 按偏好取目标',
    );
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
  List<String> sources = const [],
  String? error,
}) => rust.PluginSummaryDto(
  id: id,
  name: name ?? id,
  version: '1.0.0',
  enabled: enabled,
  requestDomains: domains,
  error: error,
  sources: sources,
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
      ..rescanGate = null
      ..routeMode = 'auto'
      ..logBatches = [];
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
    expect(
      tester.widget<SwitchListTile>(_pluginTile('示例插件')).onChanged,
      isNull,
    );
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
    expect(
      tester.widget<SwitchListTile>(_pluginTile('示例插件')).onChanged,
      isNotNull,
    );
    expect(find.textContaining('已装载 1 个'), findsOneWidget);
  });

  testWidgets('音源路由: 默认自动, 列插件选项; 点「只用内置」调 setRouteMode 并刷新', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..summaries = [_summary('demo', name: '示例插件', enabled: true)];
    await _pumpPage(tester);

    expect(find.text('音源路由'), findsOneWidget);
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('只用内置'), findsOneWidget);
    expect(find.textContaining('优先用 demo'), findsOneWidget);

    await tester.tap(find.text('只用内置'));
    await tester.pumpAndSettle();

    expect(_fake.calls, ['setRouteMode(builtin)']);
    expect(_fake.routeMode, 'builtin');
    expect(find.textContaining('音源路由已切到 只用内置'), findsOneWidget);
  });

  testWidgets('音源路由: 判定行显示 hostInactive(宿主没开 ⇒ 回内置)', (tester) async {
    _fake.summaries = [_summary('demo', name: '示例插件')];
    await _pumpPage(tester);

    expect(find.textContaining('hostInactive'), findsNWidgets(2));
    expect(find.text('当前判定 · 取直链'), findsOneWidget);
    expect(find.text('当前判定 · 搜索'), findsOneWidget);
  });

  testWidgets('Android(supported=false): 没有音源路由段', (tester) async {
    _fake.supported = false;
    await _pumpPage(tester);

    expect(find.text('音源路由'), findsNothing);
  });

  testWidgets('单插件停用: 调 disable 后重新取数, 开关跟着落下去', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..summaries = [_summary('demo', name: '示例插件', enabled: true)];
    await _pumpPage(tester);

    // 路由段加进来后插件列表在首屏以下: 先滚到可见再点(否则 tap 会打空)。
    await tester.ensureVisible(_pluginTile('示例插件'));
    await tester.pumpAndSettle();
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

    await tester.ensureVisible(find.text('重扫'));
    await tester.pumpAndSettle();
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
    await tester.ensureVisible(_pluginTile('示例插件'));
    await tester.pumpAndSettle();
    await tester.tap(_pluginTile('示例插件'));
    await tester.pumpAndSettle();

    expect(find.textContaining('插件宿主未启用'), findsOneWidget);
    // 失败不换 future ⇒ 内容还在, 没闪成错误态。
    expect(find.text('示例插件'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(_masterTile()).onChanged, isNotNull);
  });

  testWidgets('平台自报: 显示脚本 inited 声明的 sources, 未声明就写"未声明"', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..summaries = [
        _summary(
          'demo',
          name: '示例插件',
          enabled: true,
          sources: const ['kw', 'wy'],
        ),
        _summary('quiet', name: '沉默插件', enabled: true),
      ];
    await _pumpPage(tester);

    expect(find.text('平台: kw, wy'), findsOneWidget);
    expect(find.text('平台: 未声明'), findsOneWidget);
  });

  testWidgets('导入: 弹层收字段(逗号分隔的事件/白名单), 提交后调 FFI 并重取数', (tester) async {
    _fake
      ..enabled = true
      ..active = true;
    await _pumpPage(tester);

    await tester.ensureVisible(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('导入音源插件'), findsOneWidget);
    // 空正文提交 ⇒ 本地浅校验拦下, 不调 FFI.
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(_fake.calls, isEmpty);
    expect(find.textContaining('不能为空'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'id'), 'pasted');
    await tester.enterText(find.widgetWithText(TextField, '名称'), '粘贴插件');
    await tester.enterText(
      find.widgetWithText(TextField, '出站白名单'),
      'api.example.com, *.cdn.test',
    );
    await tester.enterText(
      find.widgetWithText(TextField, '脚本正文'),
      "lx.on('musicUrl', async () => 'https://cdn.test/a.mp3');",
    );
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    expect(_fake.calls, [
      'install(pasted|粘贴插件|1.0.0|musicUrl|api.example.com+*.cdn.test)',
    ]);
    expect(find.text('粘贴插件'), findsOneWidget);
  });

  testWidgets('导入: 总开关没开时入口禁用(不静默失败)', (tester) async {
    await _pumpPage(tester);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '导入'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('日志: 拉取后按插件分组显示, 再拉一次给"没有新日志"', (tester) async {
    _fake.logBatches = [
      [
        const rust.PluginLogDto(
          id: 'demo',
          lines: ['[log] boot', '[warn] slow'],
        ),
      ],
    ];
    await _pumpPage(tester);

    // 还没拉过 ⇒ 只给提示, 不凭空显示内容.
    expect(find.text('还没拉取过。'), findsOneWidget);
    await tester.ensureVisible(find.text('拉取日志'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拉取日志'));
    await tester.pumpAndSettle();

    expect(_fake.calls, ['logs']);
    expect(find.text('demo'), findsWidgets);
    expect(find.textContaining('[log] boot'), findsOneWidget);
    expect(find.textContaining('[warn] slow'), findsOneWidget);

    // 取走语义: 第二批是空的 ⇒ 页面说"没有新日志", 旧内容被替换.
    await tester.tap(find.text('拉取日志'));
    await tester.pumpAndSettle();
    expect(_fake.calls, ['logs', 'logs']);
    expect(find.text('暂时没有新日志。'), findsOneWidget);
    expect(find.textContaining('[log] boot'), findsNothing);
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

  // ---------------- 导入补全: 文件 / URL / 卸载 ----------------

  testWidgets('导入(文件): 切到「本机文件」收绝对路径, 提交调 pluginInstallFile', (tester) async {
    _fake
      ..enabled = true
      ..active = true;
    await _pumpPage(tester);

    await tester.ensureVisible(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 缺省是粘贴文本; 切成「本机文件」后字段标签换成绝对路径。
    await tester.tap(find.text('本机文件'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '文件绝对路径'), findsOneWidget);
    expect(find.widgetWithText(TextField, '脚本正文'), findsNothing);

    // 路径为空 ⇒ 本地浅校验拦下, 不调 FFI。
    await tester.enterText(find.widgetWithText(TextField, 'id'), 'fileplug');
    await tester.enterText(find.widgetWithText(TextField, '名称'), '文件插件');
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();
    expect(_fake.calls, isEmpty);
    expect(find.textContaining('不能为空'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, '文件绝对路径'),
      '/home/u/chain.js',
    );
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    expect(_fake.calls, ['installFile(fileplug|文件插件|1.0.0|/home/u/chain.js)']);
    expect(find.text('文件插件'), findsOneWidget);
    expect(find.textContaining('已导入 fileplug(本机文件)'), findsOneWidget);
  });

  testWidgets('导入(URL): 非 https 前端拦住不调 FFI, https 才调 pluginInstallUrl', (
    tester,
  ) async {
    _fake
      ..enabled = true
      ..active = true;
    await _pumpPage(tester);

    await tester.ensureVisible(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('URL'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '脚本 URL'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'id'), 'urlplug');
    await tester.enterText(find.widgetWithText(TextField, '名称'), 'URL 插件');
    await tester.enterText(
      find.widgetWithText(TextField, '脚本 URL'),
      'http://cdn.test/a.js',
    );
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    // 明文 http 在弹层里就被拦下(省一次往返, Rust 侧还有第二道)。
    expect(_fake.calls, isEmpty);
    expect(find.text('只接受 https:// 开头的链接'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, '脚本 URL'),
      'https://cdn.test/a.js',
    );
    await tester.tap(find.widgetWithText(FilledButton, '导入'));
    await tester.pumpAndSettle();

    expect(_fake.calls, [
      'installUrl(urlplug|URL 插件|1.0.0|https://cdn.test/a.js)',
    ]);
    expect(find.text('URL 插件'), findsOneWidget);
  });

  testWidgets('卸载: 二次确认(说明会删脚本与 data/), 取消不调 FFI, 确认后列表移除', (tester) async {
    _fake
      ..enabled = true
      ..active = true
      ..routeMode = 'plugin:demo'
      ..summaries = [_summary('demo', name: '示例插件', enabled: true)];
    await _pumpPage(tester);

    await tester.ensureVisible(_uninstallButton());
    await tester.pumpAndSettle();
    await tester.tap(_uninstallButton());
    await tester.pumpAndSettle();

    expect(find.text('卸载 demo?'), findsOneWidget);
    expect(find.textContaining('本地数据 data/'), findsOneWidget);
    expect(find.textContaining('会自动回到「自动」'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(_fake.calls, isEmpty);
    expect(find.text('示例插件'), findsOneWidget);

    await tester.tap(_uninstallButton());
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '卸载'));
    await tester.pumpAndSettle();

    expect(_fake.calls, ['uninstall(demo)']);
    expect(find.text('示例插件'), findsNothing);
    expect(find.textContaining('已卸载 demo'), findsOneWidget);
    // Rust 侧把指向它的路由选择回了 auto, 重取数后页面跟着回「自动」。
    expect(_fake.routeMode, 'auto');
  });

  testWidgets('卸载: 宿主总开关没开时入口禁用(不静默失败)', (tester) async {
    _fake.summaries = [_summary('demo', name: '示例插件')];
    await _pumpPage(tester);

    expect(tester.widget<IconButton>(_uninstallButton()).onPressed, isNull);
  });
}

/// 总开关那一行。
Finder _masterTile() => find.widgetWithText(SwitchListTile, '启用插件宿主');

/// 某个插件名对应的开关行。
Finder _pluginTile(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(SwitchListTile));

/// 插件行里的卸载按钮(单插件用例直接取唯一一个)。
Finder _uninstallButton() =>
    find.widgetWithIcon(IconButton, Icons.delete_outline);
