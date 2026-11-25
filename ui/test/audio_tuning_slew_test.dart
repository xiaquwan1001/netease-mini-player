import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/audio_tuning.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;

/// P-03: 增益限速斜率三端同口径。
///
/// 桌面以前恒定 3 dB/s(GainLimiter 默认, 关不掉), Android 只有动态模式才斜坡 ⇒
/// 同一份设置两端听感不同。现在斜率由设置决定 (动态开 → 3.0, 关 → 0.0),
/// 桌面原样透传给 Rust 的 player_configure, Android 原样进 ncm/player#configure。
///
/// 这里只覆盖 Dart 侧「设置 → 底层参数」的透传; 斜率本身的行为在 Rust 单测
/// (agc::tests::zero_slew_is_instant / three_db_per_sec_ramps_per_tick)。
class _FakeRustApi implements RustLibApi {
  final List<double> slewCalls = <double>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<rust.PlaybackTuningDto> crateApiPlaybackPlayerConfigure({
    required double gainDb,
    required int fadeMs,
    String? eqText,
    required double gainSlewDbPerSec,
  }) async {
    slewCalls.add(gainSlewDbPerSec);
    return rust.PlaybackTuningDto(
      gainDb: gainDb,
      fadeMs: fadeMs,
      eqFilters: 0,
      eqPreampDb: 0,
      gainSlewDbPerSec: gainSlewDbPerSec,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ncm/player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final settings = AppSettings.instance;

  late bool loudnessDynamic;
  late double volumeGainDb;
  late int fadeMs;
  late String? eqProfileText;

  setUp(() {
    loudnessDynamic = settings.loudnessDynamic;
    volumeGainDb = settings.volumeGainDb;
    fadeMs = settings.fadeMs;
    eqProfileText = settings.eqProfileText;
    settings.eqProfileText = null;
    settings.loudnessDynamic = false;
  });

  tearDown(() {
    debugForceAndroid = false;
    settings.loudnessDynamic = loudnessDynamic;
    settings.volumeGainDb = volumeGainDb;
    settings.fadeMs = fadeMs;
    settings.eqProfileText = eqProfileText;
    settings.notifyListeners();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('映射: 动态响度开/关 → 3.0 / 0.0 dB/s(与平台无关)', () {
    settings.loudnessDynamic = true;
    expect(AudioTuningRequest.fromSettings(settings).gainSlewDbPerSec, 3.0);
    expect(gainSlewForSettings(settings), kGainSlewDynamicDbPerSec);

    settings.loudnessDynamic = false;
    expect(AudioTuningRequest.fromSettings(settings).gainSlewDbPerSec, 0.0);
    expect(gainSlewForSettings(settings), kGainSlewDefaultDbPerSec);
  });

  test('请求相等性把斜率算进去: 只切动态开关也会触发一次重配', () {
    settings.loudnessDynamic = false;
    final instant = AudioTuningRequest.fromSettings(settings);
    settings.loudnessDynamic = true;
    final ramped = AudioTuningRequest.fromSettings(settings);
    expect(instant == ramped, isFalse);
    expect(instant.hashCode == ramped.hashCode, isFalse);
  });

  test('桌面: 斜率原样透传给 Rust playerConfigure (0 与 3 都透传)', () async {
    final api = _FakeRustApi();
    RustLib.initMock(api: api);
    debugForceAndroid = false;

    settings.loudnessDynamic = false;
    await applyAudioTuning(retryDelaysMs: const <int>[]);
    settings.loudnessDynamic = true;
    await applyAudioTuning(retryDelaysMs: const <int>[]);

    expect(api.slewCalls, <double>[0.0, 3.0]);
  });

  testWidgets('Android: 通道参数里的 gainSlewDbPerSec 跟着设置走', (tester) async {
    debugForceAndroid = true;

    final captured = <double>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'configure') {
        final args = call.arguments as Map;
        captured.add((args['gainSlewDbPerSec'] as num).toDouble());
      }
      return <String, Object?>{'eqApplied': true, 'eqFilters': 0};
    });

    settings.loudnessDynamic = false;
    await applyAudioTuning(retryDelaysMs: const <int>[]);
    settings.loudnessDynamic = true;
    await applyAudioTuning(retryDelaysMs: const <int>[]);

    expect(captured, <double>[0.0, 3.0]);
  });
}
