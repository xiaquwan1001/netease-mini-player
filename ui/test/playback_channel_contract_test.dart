import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/platform_is.dart' show debugForceAndroid;
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/frb_generated.dart';

/// `ncm/player` 通道与 Kotlin 侧的接口契约(审计 U2 尾巴 + U3, 2026-11-25)。
///
/// 1. `play` 带上接口时长: 原生按**请求参数**拼返回值(不回读 MediaController 的缓存),
///    所以时长必须随请求传过去, 否则换曲后进度条要等下一次 500ms 轮询才有总长。
///    **不编造**: 调用方没给(或给了 0)就不发这个键, 原生按 0 = 未知处理。
/// 2. `pauseImmediate` 是「立即静音」的独立通道: `pause` 在 Android 上是淡出语义
///    (通道立刻返回, 真正的 pause 在 fadeMs 之后), MV 起播让路只认前者。
///    通道缺失时回落 `pause`(宁可退回旧行为, 也不让暂停整个失败)。
class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  // ignore: override_on_non_overriding_member
  String crateApiPlaybackPlaybackUserAgent() => '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ncm/player');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUpAll(() {
    RustLib.initMock(api: _FakeRustApi());
  });

  setUp(() {
    debugForceAndroid = true;
    calls.clear();
    Playback.debugResetUserAgentCache();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'play' => <String, Object?>{
          'trackId': (call.arguments as Map)['trackId'],
          'playing': true,
          'positionMs': 0,
          'durationMs': (call.arguments as Map)['durationMs'] ?? 0,
          'volume': 1.0,
        },
        _ => <String, Object?>{'playing': false, 'durationMs': 284000},
      };
    });
  });

  tearDown(() {
    debugForceAndroid = false;
    Playback.debugResetUserAgentCache();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<PlayerView> play({BigInt? durationMs}) => Playback().play(
    trackId: BigInt.from(42),
    url: 'http://m701.music.126.net/2026/x/a.mp3',
    title: '主角',
    artist: '王菲',
    durationMs: durationMs,
  );

  Map<Object?, Object?> playArgs() =>
      calls.firstWhere((c) => c.method == 'play').arguments
          as Map<Object?, Object?>;

  test('play 把接口时长透传给原生, 返回值里就有总长', () async {
    final view = await play(durationMs: BigInt.from(284000));

    expect(playArgs()['durationMs'], 284000);
    expect(view.durationMs, BigInt.from(284000));
  });

  test('没给时长(或给了 0)就不发这个键, 原生按 0 = 未知', () async {
    final view = await play(durationMs: BigInt.zero);

    // 不编造: 键都不出现, 原生那边的 `?: 0L` 才会走到"未知"
    expect(playArgs().containsKey('durationMs'), isFalse);
    expect(view.durationMs, BigInt.zero);
  });

  test('pauseImmediately 走独立通道, 不碰淡出暂停', () async {
    await Playback().pauseImmediately();

    expect(calls.map((c) => c.method), ['pauseImmediate']);
  });

  test('pauseImmediate 通道缺失时回落普通 pause(旧原生也还能停)', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'pauseImmediate') {
        throw MissingPluginException(
          'No implementation found for pauseImmediate',
        );
      }
      return <String, Object?>{'playing': false};
    });

    final view = await Playback().pauseImmediately();

    expect(calls.map((c) => c.method), ['pauseImmediate', 'pause']);
    expect(view.playing, isFalse);
  });
}
