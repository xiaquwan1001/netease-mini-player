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
  late bool normalize;
  late double target;

  setUp(() {
    gain = settings.volumeGainDb;
    fade = settings.fadeMs;
    eqText = settings.eqProfileText;
    normalize = settings.loudnessNormalize;
    target = settings.loudnessTargetLufs;
  });

  tearDown(() {
    settings.volumeGainDb = gain;
    settings.fadeMs = fade;
    settings.eqProfileText = eqText;
    settings.loudnessNormalize = normalize;
    settings.loudnessTargetLufs = target;
  });

  test('R2b: 开着响度均衡时增益 = 精细音量 + 响度增益', () {
    settings.loudnessNormalize = true;
    settings.volumeGainDb = -3.0;
    final r = AudioTuningRequest.fromSettings(settings, loudnessGainDb: -6.5);
    expect(r.gainDb, closeTo(-9.5, 1e-9));
    expect(r.loudnessGainDb, -6.5);
  });

  test('R2b: 关掉响度均衡时响度增益被忽略', () {
    settings.loudnessNormalize = false;
    settings.volumeGainDb = -3.0;
    final r = AudioTuningRequest.fromSettings(settings, loudnessGainDb: -6.5);
    expect(r.gainDb, -3.0);
    expect(r.loudnessGainDb, 0.0);
  });

  test('R2b: 安静曲目的正增益可以超过 0, 但封顶 +12 dB', () {
    settings.loudnessNormalize = true;
    settings.volumeGainDb = 0.0;
    final boost = AudioTuningRequest.fromSettings(
      settings,
      loudnessGainDb: 6.0,
    );
    expect(boost.gainDb, 6.0);
    final capped = AudioTuningRequest.fromSettings(
      settings,
      loudnessGainDb: 30.0,
    );
    expect(capped.gainDb, 12.0);
  });

  test('R2b: 很响的曲目叠加后仍钳在 -40 dB', () {
    settings.loudnessNormalize = true;
    settings.volumeGainDb = -30.0;
    final r = AudioTuningRequest.fromSettings(settings, loudnessGainDb: -30.0);
    expect(r.gainDb, -40.0);
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

  test('用户音量滑块越界被钳到 -40..0(响度增益另行叠加)', () {
    settings.loudnessNormalize = false;
    settings.volumeGainDb = -80.0;
    expect(AudioTuningRequest.fromSettings(settings).gainDb, -40.0);
    settings.volumeGainDb = 12.0;
    // 用户滑块本身不会给出正增益(正增益只来自响度均衡), 这里体现为"叠加后仍 <= 12"
    expect(AudioTuningRequest.fromSettings(settings).gainDb, 12.0);
  });

  test('空白曲线归一为 null, 有效曲线原样透传', () {
    settings.eqProfileText = '   \n  ';
    expect(AudioTuningRequest.fromSettings(settings).eqText, isNull);

    const curve =
        'Preamp: -6.0 dB\nFilter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\n';
    settings.eqProfileText = curve;
    expect(AudioTuningRequest.fromSettings(settings).eqText, curve);
  });

  test('淡入档位原样透传(0/200/500/1000)', () {
    for (final ms in [0, 200, 500, 1000]) {
      settings.fadeMs = ms;
      expect(AudioTuningRequest.fromSettings(settings).fadeMs, ms);
    }
  });

  // P2-9(2026-11-28 缓存审计): 上限收敛要节流 —— Rust 侧是全目录 walk+stat,
  // 桌面每次切歌都调一次就是白烧 IO; 10 分钟内重复调用跳过, 用户显式动作(force)例外。
  test('enforceCacheLimit 10 分钟内只真跑一次, force 例外', () async {
    debugResetCacheEnforceThrottle();
    // 上限为 0 = 关闭缓存上限, 直接返回(不计数)
    settings.cacheLimitMb = 0;
    await enforceCacheLimit();
    expect(debugCacheEnforceRuns(), 0, reason: '上限关闭时不该去扫目录');

    settings.cacheLimitMb = 1024;
    await enforceCacheLimit(keepTrackId: 1);
    expect(debugCacheEnforceRuns(), 1);
    await enforceCacheLimit(keepTrackId: 2);
    await enforceCacheLimit(keepTrackId: 3);
    expect(debugCacheEnforceRuns(), 1, reason: '10 分钟内的后续切歌应被节流');

    await enforceCacheLimit(force: true);
    expect(debugCacheEnforceRuns(), 2, reason: 'force(启动/改上限)必须穿透节流');

    debugResetCacheEnforceThrottle();
    expect(debugCacheEnforceRuns(), 0);
    settings.cacheLimitMb = 512;
  });
}
