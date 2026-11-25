import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;

/// P-21: 播放 UA 的单一来源是 Rust(ncm-service 的 `platform_profile().ua`, 与取链同一常量),
/// Dart 负责把它经 `ncm/player#setUserAgent` 推给 Kotlin。
///
/// 这里钉住 Dart 这一段的三条契约:
/// 1. 启动握手(通知回调注册)时就把 UA 推过去;
/// 2. 幂等: 成功过就不再重复推(两次注册不该跨通道重复);
/// 3. 拿不到 Rust 的 UA 时**不阻断**任何流程(原生继续用兜底常量), 只留 `NCM-UA` 日志。
///
/// Kotlin 侧的兜底与 logcat 对比靠构建 + 真机验证(本仓无 JVM 测试)。
class _FakeRustApi implements RustLibApi {
  String ua = '';
  bool throwOnUa = false;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  // ignore: override_on_non_overriding_member
  String crateApiPlaybackPlaybackUserAgent() {
    if (throwOnUa) throw StateError('RustLib 未初始化');
    return ua;
  }
}

const _ua =
    'NeteaseMusic/9.1.65.240927161425(9001065);Dalvik/2.1.0 '
    '(Linux; U; Android 14; 23013RK75C Build/UKQ1.230804.001)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ncm/player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final api = _FakeRustApi();
  final calls = <MethodCall>[];

  setUpAll(() {
    // frb 一个进程只允许 initMock 一次: 用可变 fake 覆盖三种情形
    RustLib.initMock(api: api);
  });

  setUp(() {
    calls.clear();
    debugForceAndroid = true;
    Playback.debugResetUserAgentCache();
    Playback.debugResetActionStateCache();
    api.ua = _ua;
    api.throwOnUa = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    debugForceAndroid = false;
    Playback.debugResetUserAgentCache();
    Playback.debugResetActionStateCache();
    messenger.setMockMethodCallHandler(channel, null);
  });

  List<String> sentUserAgents() => calls
      .where((c) => c.method == 'setUserAgent')
      .map((c) => (c.arguments as Map)['ua'] as String)
      .toList();

  test('启动握手把 Rust 的 UA 推给原生, 且只推一次(幂等)', () async {
    Playback.setActionHandlers(onToggleLike: null, onCycleMode: null);
    await pumpEventQueue();
    expect(sentUserAgents(), <String>[_ua]);

    // 再注册一次(模拟 setSkipHandlers + setActionHandlers 两次注册): 不该重复推
    Playback.setSkipHandlers(onNext: null, onPrevious: null, onEnded: null);
    await pumpEventQueue();
    expect(sentUserAgents(), <String>[_ua]);
  });

  test('拿不到 Rust 的 UA: 不推、不抛, 原生继续用兜底常量', () async {
    api.throwOnUa = true;

    Playback.setActionHandlers(onToggleLike: null, onCycleMode: null);
    await pumpEventQueue();

    expect(sentUserAgents(), isEmpty);
    // 握手本身没被 UA 注入拖垮(原生要靠它补执行排队的通知动作)
    expect(calls.map((c) => c.method), contains('actionHandlersReady'));
  });

  test('Rust 返回空串: 不把空 UA 推给原生', () async {
    api.ua = '   ';

    Playback.setActionHandlers(onToggleLike: null, onCycleMode: null);
    await pumpEventQueue();

    expect(sentUserAgents(), isEmpty);
  });
}
