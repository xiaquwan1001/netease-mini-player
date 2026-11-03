import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';

const _libPath = String.fromEnvironment('NCM_LIB', defaultValue: '');
const _audioTest = bool.fromEnvironment('NCM_AUDIO_TEST');
const _dataDir = String.fromEnvironment('NCM_DATA_DIR', defaultValue: '/tmp/ncm-frb');

void main() {
  setUpAll(() async {
    final path = _libPath.isEmpty
        ? '${Directory.current.path}/../core/target/debug/libncm_ffi.so'
        : _libPath;
    await RustLib.init(externalLibrary: ExternalLibrary.open(path));
    await rust.init(dataDir: _dataDir);
  });

  test('ping roundtrip', () async {
    expect(await rust.ping(name: 'dart'), 'pong from rust: dart');
  });

  test('device id is stable', () async {
    final a = await rust.init(dataDir: _dataDir);
    final b = await rust.init(dataDir: _dataDir);
    expect(a.deviceId, b.deviceId);
    expect(a.deviceId.length, 52);
  });

  test('search returns typed songs', () async {
    final page = await rust.search(keywords: '晴天', limit: 3);
    expect(page.songs, isNotEmpty);
    expect(page.songs.first.id, greaterThan(BigInt.zero));
    expect(page.songs.first.name, isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('player state is idle before playing', () async {
    final state = await rust.playerState();
    expect(state.playing, false);
    expect(state.positionMs, BigInt.zero);
  });

  test('play a free track and watch position advance', () async {
    if (!_audioTest) {
      markTestSkipped('set --dart-define=NCM_AUDIO_TEST=true to run (needs audio device)');
      return;
    }
    final page = await rust.search(keywords: '晴天', limit: 10);
    final song = page.songs.firstWhere((s) => s.fee == 0 || s.fee == 8);
    final stream = await rust.songUrl(trackId: song.id, level: 'exhigh');
    final url = stream.url;
    expect(url, isNotNull);
    await rust.playTrack(trackId: song.id, url: url!);
    await Future<void>.delayed(const Duration(seconds: 2));
    final state = await rust.playerState();
    expect(state.trackId, song.id);
    expect(state.positionMs, greaterThan(BigInt.zero));
    await rust.playerStop();
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('song url for a free track', () async {
    final page = await rust.search(keywords: '晴天', limit: 10);
    for (final s in page.songs.where((s) => s.fee == 0 || s.fee == 8).take(3)) {
      final stream = await rust.songUrl(trackId: s.id, level: 'exhigh');
      expect(stream.quality, 'exhigh');
      if (stream.url != null) return;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
