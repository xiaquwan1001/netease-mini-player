import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/audio_tuning.dart';
import 'package:minincm/src/toast.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;

/// P-05 + P-06: applyAudioTuning 的"诚实化"契约。
///
/// - P-05: 读 Android `configure` 的回显, `eqApplied == false` 时打 NCM-EQ 日志 +
///   在**状态变化**时提示一次(每次 tick 都弹是骚扰)。
/// - P-06: 冷启动 `not_ready` 有限次重试; 重试用完/不可重试的异常都要留日志, 不再
///   被 `catch (_) {}` 静默吞掉。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ncm/player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final settings = AppSettings.instance;

  String? eqText;
  bool loudnessDynamic = false;

  setUp(() {
    debugForceAndroid = true;
    resetAudioTuningNotices();
    eqText = settings.eqProfileText;
    loudnessDynamic = settings.loudnessDynamic;
    settings.eqProfileText = null;
    settings.loudnessDynamic = false;
  });

  tearDown(() {
    debugForceAndroid = false;
    settings.eqProfileText = eqText;
    settings.loudnessDynamic = loudnessDynamic;
    settings.notifyListeners();
    messenger.setMockMethodCallHandler(channel, null);
    resetAudioTuningNotices();
  });

  /// 触发一次 applyAudioTuning 并推进假时钟。
  ///
  /// P-06 的重试用 `Future.delayed`, 在 testWidgets 的假时钟里必须 pump 才会到点;
  /// 直接 `await` 会一直等到测试超时。
  Future<void> runApply(
    WidgetTester tester, {
    List<int> retryDelaysMs = const <int>[],
  }) async {
    var done = false;
    unawaited(
      applyAudioTuning(retryDelaysMs: retryDelaysMs)
          .whenComplete(() => done = true),
    );
    for (var i = 0; i < 200 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(done, isTrue, reason: 'applyAudioTuning 没有在限定帧数内结束');
    await tester.pumpAndSettle();
  }

  /// 挂一棵带根 messenger 的树: 后台提示走 rootMessengerKey(见 src/toast.dart)。
  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        scaffoldMessengerKey: rootMessengerKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pump();
  }

  test('isTuningNotReady: 只认服务/core 未就绪', () {
    expect(isTuningNotReady(PlatformException(code: 'not_ready')), isTrue);
    expect(isTuningNotReady(Exception('core not initialized')), isTrue);
    expect(isTuningNotReady(PlatformException(code: 'bad_args')), isFalse);
    expect(isTuningNotReady(Exception('EQ 第 1 行: 数值越界')), isFalse);
  });

  testWidgets('P-05: eqApplied=false 打日志并提示一次, 重复调用不再打扰', (tester) async {
    await pumpHost(tester);

    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return <String, Object?>{
        'eqApplied': false,
        'eqError': '第 2 行: Gain 超出 ±24 dB',
        'eqFilters': 0,
      };
    });

    await runApply(tester);
    expect(calls, 1);
    expect(find.textContaining('自定义响度曲线未生效'), findsOneWidget);
    expect(find.textContaining('第 2 行'), findsOneWidget);

    // 让提示自动回落, 再调一次同样的状态: 不应再弹(否则每 200ms 一个 snackbar)
    await tester.pump(kToastDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('自定义响度曲线未生效'), findsNothing);

    await runApply(tester);
    expect(calls, 2);
    expect(find.textContaining('自定义响度曲线未生效'), findsNothing);
  });

  testWidgets('P-05: 曲线恢复生效后再次失败, 属于状态变化, 会再提示一次', (tester) async {
    await pumpHost(tester);

    var applied = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'eqApplied': applied,
        'eqError': applied ? null : '第 1 行: filter 数超过 20',
        'eqFilters': applied ? 10 : 0,
      };
    });

    await runApply(tester);
    expect(find.textContaining('自定义响度曲线未生效'), findsOneWidget);
    await tester.pump(kToastDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();

    // 生效了: 不提示, 且清掉"已提示"状态
    applied = true;
    await runApply(tester);
    expect(find.textContaining('自定义响度曲线未生效'), findsNothing);

    // 再次失败 = 又一次状态变化
    applied = false;
    await runApply(tester);
    expect(find.textContaining('自定义响度曲线未生效'), findsOneWidget);
  });

  testWidgets('P-05: eqApplied=true 不提示', (tester) async {
    await pumpHost(tester);
    messenger.setMockMethodCallHandler(channel, (call) async {
      return <String, Object?>{
        'eqApplied': true,
        'eqError': null,
        'eqFilters': 10,
      };
    });

    await runApply(tester);
    expect(find.textContaining('未生效'), findsNothing);
  });

  testWidgets('P-06: 冷启动 not_ready 会重试, 服务起来后成功且不提示', (tester) async {
    await pumpHost(tester);

    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      if (calls == 1) {
        throw PlatformException(
          code: 'not_ready',
          message: 'PlaybackService 尚未创建',
        );
      }
      return <String, Object?>{'eqApplied': true, 'eqFilters': 0};
    });

    await runApply(tester, retryDelaysMs: const <int>[0, 0, 0]);
    expect(calls, 2);
    expect(find.textContaining('播放参数暂未生效'), findsNothing);
  });

  testWidgets('P-06: 重试用完仍失败 ⇒ 日志 + 只提示一次', (tester) async {
    await pumpHost(tester);

    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      throw PlatformException(code: 'not_ready', message: '尚未创建');
    });

    await runApply(tester, retryDelaysMs: const <int>[0, 0, 0]);
    // 1 次首发 + 3 次重试
    expect(calls, 4);
    expect(find.textContaining('播放参数暂未生效'), findsOneWidget);

    await tester.pump(kToastDuration + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    // 下一轮 tick 再失败: 仍会重试, 但不再弹第二条提示
    await runApply(tester, retryDelaysMs: const <int>[0, 0, 0]);
    expect(calls, 8);
    expect(find.textContaining('播放参数暂未生效'), findsNothing);
  });

  testWidgets('P-06: 不可重试的异常不重试, 但也不静默', (tester) async {
    await pumpHost(tester);

    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      throw PlatformException(code: 'bad_args', message: 'eqText 类型不对');
    });

    await runApply(tester, retryDelaysMs: const <int>[0, 0, 0]);
    expect(calls, 1);
    expect(find.textContaining('播放参数暂未生效'), findsOneWidget);
  });
}
