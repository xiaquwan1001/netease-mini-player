import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;

/// P-02(通知按钮红心/模式状态自愈)的 Dart 侧契约:
///
/// - **幂等**: 与上次成功推送的值相同就不跨通道(轮询每 5s 的定时重推靠它短路);
/// - **握手**: 通知回调注册好之后, 主动告诉原生 `actionHandlersReady`
///   (原生据此执行"上划清任务后点通知按钮"排队下来的意图, P-01);
/// - **自愈**: 原生 `syncActionState` 请求到达时, 用最近已知状态立刻重推一次;
/// - **可观测可重试**: 推送失败不记为已推送, 下一次同值也会重推(以前是静默吞掉)。
///
/// 注: Kotlin 侧(按钮槽位/兜底拉起/静态状态)本仓无 JVM 测试, 只能靠构建 + 模拟器验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ncm/player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];
  var failNextPush = false;

  /// 模拟原生 → Dart: 直接投递一条 MethodChannel 方法调用
  Future<void> deliverNative(String method) async {
    final data = const StandardMethodCodec().encodeMethodCall(
      MethodCall(method),
    );
    await messenger.handlePlatformMessage(channel.name, data, (_) {});
    await pumpEventQueue();
  }

  List<MethodCall> statePushes() =>
      calls.where((c) => c.method == 'setActionState').toList();

  setUp(() {
    calls.clear();
    failNextPush = false;
    debugForceAndroid = true;
    Playback.debugResetActionStateCache();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setActionState' && failNextPush) {
        failNextPush = false;
        throw PlatformException(code: 'not_ready', message: '服务尚未创建');
      }
      return null;
    });
    // 静态回调跨用例保留: 先把两组都清空, 免得上一个用例的闭包吃掉本用例的原生动作
    Playback.setSkipHandlers();
    Playback.debugResetActionStateCache();
    calls.clear();
    // 注册 Dart 侧回调(与 main.dart 的接线同形), 顺带触发 actionHandlersReady 握手
    Playback.setActionHandlers(onToggleLike: null, onCycleMode: null);
  });

  tearDown(() {
    debugForceAndroid = false;
    Playback.debugResetActionStateCache();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('回调注册后向原生发握手 actionHandlersReady', () async {
    await pumpEventQueue();
    expect(calls.map((c) => c.method), contains('actionHandlersReady'));
  });

  test('相同状态只推送一次(幂等)', () async {
    await Playback().setActionState(liked: true, modeIcon: 'shuffle');
    await Playback().setActionState(liked: true, modeIcon: 'shuffle');
    await Playback().setActionState(liked: true, modeIcon: 'shuffle');
    expect(statePushes(), hasLength(1));
    expect(statePushes().single.arguments, {
      'liked': true,
      'modeIcon': 'shuffle',
    });
  });

  test('状态变化才再推', () async {
    await Playback().setActionState(liked: true, modeIcon: 'shuffle');
    await Playback().setActionState(liked: false, modeIcon: 'shuffle');
    await Playback().setActionState(liked: false, modeIcon: 'repeatOne');
    expect(statePushes(), hasLength(3));
    expect(statePushes().last.arguments, {
      'liked': false,
      'modeIcon': 'repeatOne',
    });
  });

  test('推送失败不记成功, 下一次同值仍重试', () async {
    failNextPush = true;
    await Playback().setActionState(liked: true, modeIcon: 'sequence');
    expect(statePushes(), hasLength(1)); // 失败也发了通道调用(抛出被吞成日志)
    await Playback().setActionState(liked: true, modeIcon: 'sequence');
    expect(statePushes(), hasLength(2)); // 未记成功 ⇒ 同值也重推
    await Playback().setActionState(liked: true, modeIcon: 'sequence');
    expect(statePushes(), hasLength(2)); // 这次成功了 ⇒ 同值短路
  });

  test('原生 syncActionState 请求 → 用最近已知状态重推', () async {
    await Playback().setActionState(liked: true, modeIcon: 'repeat');
    calls.clear();
    await deliverNative('syncActionState');
    expect(statePushes(), hasLength(1));
    expect(statePushes().single.arguments, {
      'liked': true,
      'modeIcon': 'repeat',
    });
  });

  test('没有已知状态时 syncActionState 不空推', () async {
    calls.clear();
    await deliverNative('syncActionState');
    expect(statePushes(), isEmpty);
  });

  test('原生 skipNext 仍转发给 Dart 队列回调', () async {
    var next = 0;
    Playback.setSkipHandlers(onNext: () => next++);
    await deliverNative('skipNext');
    expect(next, 1);
  });

  test('回调未注册时到达的原生动作排队, 注册后按到达顺序补执行', () async {
    // 首次握手(setSkipHandlers)比 setActionHandlers 先发生, 中间到达的点击以前会被静默丢掉
    final seen = <String>[];
    await deliverNative('skipNext');
    await deliverNative('skipPrevious');
    expect(seen, isEmpty); // 此刻还没有消费者
    Playback.setSkipHandlers(
      onNext: () => seen.add('next'),
      onPrevious: () => seen.add('prev'),
    );
    expect(seen, ['next', 'prev']);
  });

  test('未知原生动作只记日志, 不排队也不执行', () async {
    var next = 0;
    await deliverNative('bogusAction');
    Playback.setSkipHandlers(onNext: () => next++);
    await deliverNative('skipNext');
    expect(next, 1);
  });
}
