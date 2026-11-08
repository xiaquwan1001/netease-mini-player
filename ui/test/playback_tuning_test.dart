import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playback.dart';

/// S3: Playback.applyTuning 门面契约。
/// - 非 Android 平台直接返回 null(不抛错, Linux 由 Rust 侧处理)。
/// - Android 走 ncm/player#configure 通道, 参数 map 形状固定 7 键。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ncm/player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    Playback.debugForceAndroid = false;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('非 Android 平台返回 null, 不抛错', () async {
    Playback.debugForceAndroid = false;
    final result = await Playback().applyTuning(
      gainDb: -6.0,
      fadeMs: 500,
      hardwareDecode: false,
      streamCache: true,
      cacheLimitMb: 1024,
      eqText: 'Preamp: -6.0 dB\n',
    );
    expect(result, isNull);
  });

  test('Android 走 configure 通道, 参数 map 形状正确且透传 eqText/gainSlewDbPerSec', () async {
    Playback.debugForceAndroid = true;

    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return <String, Object?>{
        'gainDb': -6.0,
        'fadeMs': 500,
        'hardwareDecode': false,
        'streamCache': true,
        'cacheLimitMb': 1024,
        'gainSlewDbPerSec': 3.0,
        'eqApplied': true,
        'eqError': null,
        'eqFilters': 1,
      };
    });

    const eqText = 'Preamp: -6.0 dB\nFilter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\n';
    final result = await Playback().applyTuning(
      gainDb: -6.0,
      fadeMs: 500,
      hardwareDecode: false,
      streamCache: true,
      cacheLimitMb: 1024,
      eqText: eqText,
      gainSlewDbPerSec: 3.0,
    );

    final call = captured;
    if (call == null) fail('configure 通道未被调用');
    expect(call.method, 'configure');

    final args = call.arguments;
    if (args is! Map) fail('configure 参数应为 Map');
    expect(args.keys.toSet(), {
      'gainDb',
      'fadeMs',
      'hardwareDecode',
      'streamCache',
      'cacheLimitMb',
      'eqText',
      'gainSlewDbPerSec',
    });
    expect(args['gainDb'], -6.0);
    expect(args['fadeMs'], 500);
    expect(args['hardwareDecode'], false);
    expect(args['streamCache'], true);
    expect(args['cacheLimitMb'], 1024);
    expect(args['eqText'], eqText);
    expect(args['gainSlewDbPerSec'], 3.0);

    // 回显透传(便于 Dart 侧断言配置真的落地)
    final echo = result;
    if (echo == null) fail('applyTuning 应返回回显 map');
    expect(echo['eqApplied'], true);
    expect(echo['eqFilters'], 1);
    expect(echo['gainDb'], -6.0);
    expect(echo['gainSlewDbPerSec'], 3.0);
  });

  test('eqText 为 null 时照常发送(旁路 EQ)', () async {
    Playback.debugForceAndroid = true;

    MethodCall? captured;
    messenger.setMockMethodCallHandler(channel, (call) async {
      captured = call;
      return <String, Object?>{'eqApplied': true, 'eqError': null};
    });

    final result = await Playback().applyTuning(
      gainDb: 0,
      fadeMs: 0,
      hardwareDecode: true,
      streamCache: true,
      cacheLimitMb: 512,
    );

    final call = captured;
    if (call == null) fail('configure 通道未被调用');
    final args = call.arguments;
    if (args is! Map) fail('configure 参数应为 Map');
    expect(args['eqText'], isNull);
    expect(args['gainDb'], 0);
    expect(args['fadeMs'], 0);
    // 未显式传限速时默认 0 = 瞬时(静态 RG2.0 行为不变)
    expect(args['gainSlewDbPerSec'], 0.0);

    final echo = result;
    if (echo == null) fail('applyTuning 应返回回显 map');
    expect(echo['eqApplied'], true);
  });
}
