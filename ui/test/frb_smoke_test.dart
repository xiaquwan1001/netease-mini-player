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

  test('lyric lines are parsed and sorted', () async {
    // 周杰伦 - 晴天(免费, 歌词必有)
    final lines = await rust.lyricLinesI18N(trackId: BigInt.from(186016));
    expect(lines, isNotEmpty);
    for (var i = 1; i < lines.length; i++) {
      expect(lines[i].timeMs >= lines[i - 1].timeMs, true, reason: '歌词必须按时间升序');
    }
    expect(lines.first.timeMs, BigInt.zero);
    expect(lines.map((l) => l.text).any((t) => t.isNotEmpty), true);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('english song lyric carries translation', () async {
    // Ed Sheeran - Shape of You: 有 tlyric, 用来守住"按时间戳合并翻译"
    final lines = await rust.lyricLinesI18N(trackId: BigInt.from(451703096));
    expect(lines, isNotEmpty);
    expect(lines.where((l) => l.sub != null), isNotEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('song url for a free track', () async {
    final page = await rust.search(keywords: '晴天', limit: 10);
    for (final s in page.songs.where((s) => s.fee == 0 || s.fee == 8).take(3)) {
      final stream = await rust.songUrl(trackId: s.id, level: 'exhigh');
      expect(stream.quality, 'exhigh');
      if (stream.url != null) return;
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('daily recommend songs are typed', () async {
    final songs = await rust.dailyRecommendSongs();
    expect(songs, isNotEmpty);
    expect(songs.first.id, greaterThan(BigInt.zero));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('search suggestions are typed', () async {
    final items = await rust.searchSuggest(keywords: '晴天');
    expect(items, isNotEmpty);
    expect(items.first.title, isNotEmpty);
    expect(['song', 'artist', 'album', 'playlist'], contains(items.first.kind));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('album detail carries cover and songs', () async {
    final album = await rust.albumDetail(albumId: BigInt.from(255723258));
    expect(album.name, isNotEmpty);
    expect(album.coverUrl, isNotNull);
    expect(album.songs, isNotEmpty);
    expect(album.songs.first.albumId, album.id);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('podcast hot list and programs are typed', () async {
    final radios = await rust.podcastHot(limit: 3);
    expect(radios, isNotEmpty);
    expect(radios.first.programCount, greaterThan(BigInt.zero));
    final programs = await rust.podcastPrograms(
      radioId: radios.first.id,
      limit: 3,
      offset: 0,
    );
    expect(programs, isNotEmpty);
    expect(programs.first.song, isNotNull);
    expect(programs.first.song!.id, greaterThan(BigInt.zero));
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('search history roundtrip stays local', () async {
    await rust.clearSearchHistory();
    await rust.recordSearch(keyword: '晴天');
    await rust.recordSearch(keyword: '七里香');
    final list = await rust.searchHistory();
    expect(list.take(2), ['七里香', '晴天']);
    await rust.clearSearchHistory();
    expect(await rust.searchHistory(), isEmpty);
  });

  test('local play history records a song', () async {
    final page = await rust.search(keywords: '晴天', limit: 1);
    final song = page.songs.first;
    await rust.rememberPlay(song: song);
    final recent = await rust.localRecentSongs(limit: 5);
    expect(recent.any((s) => s.id == song.id), true);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
