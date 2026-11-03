import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';

const _libPath = String.fromEnvironment('NCM_LIB', defaultValue: '');
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

  test('song url for a free track', () async {
    final page = await rust.search(keywords: '晴天', limit: 10);
    for (final s in page.songs.where((s) => s.fee == 0 || s.fee == 8).take(3)) {
      final stream = await rust.songUrl(trackId: s.id, level: 'exhigh');
      expect(stream.quality, 'exhigh');
      if (stream.url != null) return;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
