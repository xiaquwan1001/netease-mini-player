import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/audio_tuning.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;

/// 用户需求(2026-11): 「播放被其他流媒体抢占」要有明确选项。
///
/// 覆盖三件事:
/// 1. 三档策略的 id ↔ 落盘值的映射(未知值回落默认, 不能让手改坏的文件变成"叠音");
/// 2. 设置 → 底层 configure 参数的透传(改完立刻生效的那条路径);
/// 3. 「策略变了」要被 [AudioTuningRequest] 的相等性感知到, 否则改写后不会重配。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('ncm/player');
  final settings = AppSettings.instance;

  late String originalLevel;
  late AudioFocusPolicy originalFocus;

  setUp(() {
    originalLevel = settings.audioLevel;
    originalFocus = settings.audioFocus;
  });

  tearDown(() {
    debugForceAndroid = false;
    settings.audioLevel = originalLevel;
    settings.audioFocus = originalFocus;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('id 映射: 未知/空/null 一律回落「跟随系统」', () {
    expect(
      AudioFocusPolicy.fromId('followSystem'),
      AudioFocusPolicy.followSystem,
    );
    expect(AudioFocusPolicy.fromId('alwaysPlay'), AudioFocusPolicy.alwaysPlay);
    expect(AudioFocusPolicy.fromId('alwaysStop'), AudioFocusPolicy.alwaysStop);
    expect(AudioFocusPolicy.fromId(null), AudioFocusPolicy.followSystem);
    expect(AudioFocusPolicy.fromId(''), AudioFocusPolicy.followSystem);
    expect(AudioFocusPolicy.fromId('nonsense'), AudioFocusPolicy.followSystem);
    // id 是落盘与 Kotlin `AudioFocusMode.fromId` 的契约, 改名要两边一起改
    expect(AudioFocusPolicy.values.map((p) => p.id), [
      'followSystem',
      'alwaysPlay',
      'alwaysStop',
    ]);
  });

  test('设置 → AudioTuningRequest: 带上策略; 只改这一项也会触发重配', () {
    settings.audioFocus = AudioFocusPolicy.followSystem;
    final follow = AudioTuningRequest.fromSettings(settings);
    expect(follow.audioFocus, AudioFocusPolicy.followSystem);

    settings.audioFocus = AudioFocusPolicy.alwaysStop;
    final stop = AudioTuningRequest.fromSettings(settings);
    expect(stop.audioFocus, AudioFocusPolicy.alwaysStop);
    // 相等性必须算进策略: onAudioSettingsChanged 靠 `request != _lastTuning`
    // 决定要不要重调 applyAudioTuning ⇒ 漏了这条, 改完设置不会生效。
    expect(follow == stop, isFalse);
    expect(follow.hashCode == stop.hashCode, isFalse);
  });

  test('落盘往返: 策略写进 settings.json, 重建后能读回', () async {
    final dir = await Directory.systemTemp.createTemp('ncm-audio-focus');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    await settings.load(dir.path);
    settings.audioFocus = AudioFocusPolicy.alwaysPlay;
    await settings.update();
    final raw = File('${dir.path}/settings.json').readAsStringSync();
    expect(raw, contains('"audioFocus":"alwaysPlay"'));

    settings.audioFocus = AudioFocusPolicy.followSystem;
    await settings.load(dir.path);
    expect(settings.audioFocus, AudioFocusPolicy.alwaysPlay);
    settings.audioFocus = originalFocus;
  });

  testWidgets('Android configure 通道带上 audioFocus, 改设置立刻重推', (tester) async {
    debugForceAndroid = true;
    final captured = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'configure') {
        final args = call.arguments as Map;
        captured.add(args['audioFocus'] as String);
      }
      return <String, Object?>{'eqApplied': true, 'eqFilters': 0};
    });

    settings.audioFocus = AudioFocusPolicy.alwaysPlay;
    await applyAudioTuning(retryDelaysMs: const <int>[]);
    settings.audioFocus = AudioFocusPolicy.alwaysStop;
    await applyAudioTuning(retryDelaysMs: const <int>[]);

    expect(captured, <String>['alwaysPlay', 'alwaysStop']);
  });
}
