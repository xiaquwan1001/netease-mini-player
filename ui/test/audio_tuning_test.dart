import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/audio_tuning.dart';

/// R2/R5/R7: AppSettings -> Rust PlaybackTuning 的映射契约。
/// (真正的 FFI 调用在 Rust 侧有单测; 这里只锁 Dart 侧的取值与归一化规则)
void main() {
  final settings = AppSettings.instance;
  late double gain;
  late int fade;
  late String? eqText;

  setUp(() {
    gain = settings.volumeGainDb;
    fade = settings.fadeMs;
    eqText = settings.eqProfileText;
  });

  tearDown(() {
    settings.volumeGainDb = gain;
    settings.fadeMs = fade;
    settings.eqProfileText = eqText;
  });

  test('默认值: 0 dB / 0 ms / 曲线旁路', () {
    settings.volumeGainDb = 0.0;
    settings.fadeMs = 0;
    settings.eqProfileText = null;
    final r = AudioTuningRequest.fromSettings(settings);
    expect(r.gainDb, 0.0);
    expect(r.fadeMs, 0);
    expect(r.eqText, isNull);
  });

  test('越界增益被钳到 -40..0', () {
    settings.volumeGainDb = -80.0;
    expect(AudioTuningRequest.fromSettings(settings).gainDb, -40.0);
    settings.volumeGainDb = 12.0;
    expect(AudioTuningRequest.fromSettings(settings).gainDb, 0.0);
  });

  test('空白曲线归一为 null, 有效曲线原样透传', () {
    settings.eqProfileText = '   \n  ';
    expect(AudioTuningRequest.fromSettings(settings).eqText, isNull);

    const curve = 'Preamp: -6.0 dB\nFilter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\n';
    settings.eqProfileText = curve;
    expect(AudioTuningRequest.fromSettings(settings).eqText, curve);
  });

  test('淡入档位原样透传(0/200/500/1000)', () {
    for (final ms in [0, 200, 500, 1000]) {
      settings.fadeMs = ms;
      expect(AudioTuningRequest.fromSettings(settings).fadeMs, ms);
    }
  });
}
