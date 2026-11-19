// T5: PlaybackCoordinator 直测(审计 7.5)。
//
// 拆壳 S4 之后"播放态轮询 / 换曲副作用 / 播完续播 / 取链跳过 / 现场恢复"这几条
// 主链全在这个类里, 但此前只有 home_page 的间接覆盖(整页 pump, 断言只能落在
// 播放条文案上)。这里直接构造协调器 + 现有 fake(SongDto 工厂) + RustLib 替身,
// 把每条主链与关键错误分支钉住:
//
// - 换曲 → 主色/通知栏动作态同步(= "切歌后歌词背景与红心图标跟着走")
// - 轮询值不变不重建(暂停时 500ms 一次空重建)
// - 播完兜底续播 / 队尾停住 / 拖动中不判定 / 原生 ENDED 与轮询共用临界区
// - 引导态(心动模式)续播不看 PlayMode
// - 取链失败/VIP 策略跳过, 主动点选不跳过, 预取直链一次性使用
// - 恢复现场 → 播放条显示但不播 → 按播放从保存位置续播
// - 睡眠定时「播完这首」到点后不再续播
//
// RustLib.initMock 每个进程只能调一次(见 eq_import_flow_test.dart), 所以替身是
// 全局单实例 + 每个用例 reset 行为。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/home/lyric_controller.dart';
import 'package:minincm/src/home/playback_coordinator.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/playback_state.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/sleep_timer.dart';

import 'support/fakes.dart';

/// Rust 侧替身: 只实现被测代码真的会调的入参。
///
/// 没实现的方法走 noSuchMethod 抛 UnimplementedError —— 一旦被测代码新增了
/// 未预期的 FFI 调用, 用例会立刻红, 而不是静默跑过去。
class _FakeApi implements RustLibApi {
  /// 取链返回的直链。null = 上游没给直链(会员/版权限制)。
  String? defaultUrl = 'http://m801.music.126.net/track.mp3';

  /// 按曲目 id 覆盖直链(不存在的键用 [defaultUrl])。
  final Map<String, String?> urlByTrack = <String, String?>{};

  /// 非 null = 取链抛这个错(模拟断网/风控)。
  Object? songUrlError;

  final List<BigInt> songUrlCalls = <BigInt>[];

  void reset() {
    defaultUrl = 'http://m801.music.126.net/track.mp3';
    urlByTrack.clear();
    songUrlError = null;
    songUrlCalls.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<rust.StreamUrl> crateApiSongUrl({
    required BigInt trackId,
    required String level,
  }) async {
    songUrlCalls.add(trackId);
    final err = songUrlError;
    if (err != null) throw err;
    final key = trackId.toString();
    return rust.StreamUrl(
      url: urlByTrack.containsKey(key) ? urlByTrack[key] : defaultUrl,
      quality: level,
      isTrial: false,
    );
  }

  @override
  Future<bool> crateApiRememberPlay({required rust.SongDto song}) async => true;

  @override
  Future<rust.WordLyricDto> crateApiWordLyricLines({
    required BigInt trackId,
  }) async => const rust.WordLyricDto(
    lines: <rust.WordLyricLineDto>[],
    translationLines: <String?>[],
    hasWordTiming: false,
  );

  @override
  Future<rust.WordLyricDto?> crateApiTtmlLyricLines({
    required BigInt trackId,
  }) async => null;

  @override
  Future<List<rust.LyricLineDto>> crateApiLyricLinesI18N({
    required BigInt trackId,
  }) async => const <rust.LyricLineDto>[];

  @override
  Future<String> crateApiLyric({required BigInt trackId}) async => '';

  @override
  Future<rust.LoudnessDto?> crateApiLoudnessCached({
    required BigInt trackId,
    required double targetLufs,
  }) async => null;

  @override
  Future<rust.PlaybackTuningDto> crateApiPlayerConfigure({
    required double gainDb,
    required int fadeMs,
    String? eqText,
    required double gainSlewDbPerSec,
  }) async => rust.PlaybackTuningDto(
    gainDb: gainDb,
    fadeMs: fadeMs,
    eqFilters: 0,
    eqPreampDb: 0,
    gainSlewDbPerSec: gainSlewDbPerSec,
  );
}

/// 播放门面替身: 播放态由用例直接摆放, 播放/暂停/停止只记录调用。
class _FakePlayback extends Playback {
  PlayerView current = PlayerView.empty;

  /// 非 null = state() 抛错(MediaController 连接中)。
  Object? stateError;

  /// play() 成功后的播放态(默认按入参曲目造一个"播放中")。
  PlayerView? playState;

  final List<({BigInt trackId, String url, String title})> plays =
      <({BigInt trackId, String url, String title})>[];

  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;

  @override
  Future<PlayerView> state() async {
    final err = stateError;
    if (err != null) throw err;
    return current;
  }

  @override
  Future<PlayerView> play({
    required BigInt trackId,
    required String url,
    required String title,
    required String artist,
    BigInt? durationMs,
    Uint8List? artwork,
  }) async {
    plays.add((trackId: trackId, url: url, title: title));
    current =
        playState ??
        PlayerView(
          trackId: trackId,
          playing: true,
          positionMs: BigInt.zero,
          durationMs: durationMs ?? BigInt.from(1000),
          volume: 1.0,
        );
    return current;
  }

  @override
  Future<PlayerView> pause() async {
    pauseCalls += 1;
    current = _copy(current, playing: false);
    return current;
  }

  @override
  Future<PlayerView> resume() async {
    resumeCalls += 1;
    current = _copy(current, playing: true);
    return current;
  }

  @override
  Future<PlayerView> stop() async {
    stopCalls += 1;
    current = PlayerView.empty;
    return current;
  }

  static PlayerView _copy(PlayerView v, {required bool playing}) => PlayerView(
    trackId: v.trackId,
    playing: playing,
    positionMs: v.positionMs,
    durationMs: v.durationMs,
    volume: v.volume,
    seekable: v.seekable,
    pendingSeekMs: v.pendingSeekMs,
  );
}

PlayerView _view({
  BigInt? trackId,
  bool playing = false,
  int positionMs = 0,
  int durationMs = 1000,
}) => PlayerView(
  trackId: trackId,
  playing: playing,
  positionMs: BigInt.from(positionMs),
  durationMs: BigInt.from(durationMs),
  volume: 1.0,
);

/// 模拟页面的接线: 真 PlayQueue + 真 LyricController + 记录侧效应。
class _Harness {
  _Harness({
    List<rust.SongDto>? songs,
    int startAt = 0,
    this.dataDir,
    this.sleepTimer,
  }) {
    if (songs != null) queue.setAll(songs, startAt: startAt);
    coordinator.addListener(() => notifies += 1);
  }

  final _FakePlayback playback = _FakePlayback();
  final PlayQueue<rust.SongDto> queue = PlayQueue<rust.SongDto>();
  final String? dataDir;
  final SleepTimer? sleepTimer;

  final List<String> toasts = <String>[];
  final List<String> errors = <String>[];
  final List<double> seeks = <double>[];

  /// 引导态(心动模式/私人FM)与它的"下一首"结果序列。
  QueueGuide guide = QueueGuide.none;
  final List<rust.SongDto?> guideResults = <rust.SongDto?>[];

  int paletteCalls = 0;
  int actionCalls = 0;
  int queueChangedCalls = 0;
  int startedCalls = 0;
  int restoredCalls = 0;
  int notifies = 0;

  late final LyricController lyric = LyricController(
    player: () => coordinator.player,
    pollPlayer: () => coordinator.poll(),
    itemExtentOf: () => 56,
    toast: toasts.add,
  );

  late final PlaybackCoordinator coordinator = PlaybackCoordinator(
    playback: playback,
    queue: queue,
    lyric: lyric,
    dataDirOf: () => dataDir,
    libraryTitleOf: () => '正在播放',
    toast: toasts.add,
    toastError: errors.add,
    dragActive: () => dragging,
    seekTo: (ms) async => seeks.add(ms),
    onPlaybackStarted: (playlistId, source) => startedCalls += 1,
    onRestored: () => restoredCalls += 1,
    guideOf: () => guide,
    guideNext: () async =>
        guideResults.isEmpty ? null : guideResults.removeAt(0),
    queueChanged: () => queueChangedCalls += 1,
    syncCoverPalette: () async => paletteCalls += 1,
    syncActionState: () async => actionCalls += 1,
    sleepTimer: sleepTimer,
  );

  bool dragging = false;

  void dispose() {
    coordinator.dispose();
    lyric.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final api = _FakeApi();
  RustLib.initMock(api: api);

  final settings = AppSettings.instance;
  late String audioLevel;
  late bool skipVipSongs;
  late bool loudnessNormalize;
  late int cacheLimitMb;

  setUp(() {
    api.reset();
    audioLevel = settings.audioLevel;
    skipVipSongs = settings.skipVipSongs;
    loudnessNormalize = settings.loudnessNormalize;
    cacheLimitMb = settings.cacheLimitMb;
    settings.loudnessNormalize = false;
    settings.skipVipSongs = false;
    settings.cacheLimitMb = 0; // 关掉缓存收敛, 免得多余 FFI
  });

  tearDown(() {
    settings.audioLevel = audioLevel;
    settings.skipVipSongs = skipVipSongs;
    settings.loudnessNormalize = loudnessNormalize;
    settings.cacheLimitMb = cacheLimitMb;
    settings.notifyListeners();
  });

  group('换曲副作用(切歌 → 主色/动作态)', () {
    test('轮询发现换曲: 主色与通知栏动作态各同步, 值不变不重复重建', () async {
      final h = _Harness(songs: [fakeSong(id: 1), fakeSong(id: 2)]);
      addTearDown(h.dispose);

      h.playback.current = _view(trackId: BigInt.one, playing: true);
      await h.coordinator.poll();
      expect(h.paletteCalls, 1, reason: '首播/换曲要按新封面重算主色');
      final firstActionCalls = h.actionCalls;
      expect(
        firstActionCalls,
        greaterThanOrEqualTo(1),
        reason: '换曲 + 首轮节流自愈, 至少推一次红心/模式',
      );
      final firstRebuilds = h.notifies;
      expect(firstRebuilds, 1, reason: '播放态从空 → 有曲目, 只该重建一次');

      // 同一首、同一位置: 暂停态下每 500ms 一次空重建是用户反馈过的耗电项
      await h.coordinator.poll();
      expect(h.paletteCalls, 1, reason: '同一首曲目不再重算主色');
      expect(h.actionCalls, firstActionCalls, reason: '5s 节流内不重复推动作态');
      expect(h.notifies, firstRebuilds, reason: '值没变不重建');

      // 换到第二首
      h.playback.current = _view(trackId: BigInt.two, playing: true);
      await h.coordinator.poll();
      expect(h.paletteCalls, 2, reason: '换曲必须重新取主色');
      expect(h.actionCalls, firstActionCalls + 1, reason: '通知栏红心跟新曲目走');
      expect(h.coordinator.player!.trackId, BigInt.two);
    });

    test('播放后端未就绪(state() 抛错)时轮询静默忽略, 不清播放条', () async {
      final h = _Harness(songs: [fakeSong(id: 1)]);
      addTearDown(h.dispose);
      h.coordinator.adoptPlayer(_view(trackId: BigInt.one, playing: true));
      final rebuilds = h.notifies;

      h.playback.stateError = PlatformExceptionLike('not ready');
      await h.coordinator.poll();
      expect(h.coordinator.player!.trackId, BigInt.one, reason: '状态不丢');
      expect(h.notifies, rebuilds);
      expect(h.errors, isEmpty, reason: '连接中不该弹错');
    });

    test('dispose 之后轮询不再重建(防止拆页面后仍 notify)', () async {
      final h = _Harness(songs: [fakeSong(id: 1)]);
      h.playback.current = _view(trackId: BigInt.one, playing: true);
      h.coordinator.dispose();
      await h.coordinator.poll();
      expect(h.notifies, 0);
      h.lyric.dispose();
    });
  });

  group('播完续播', () {
    test('播完兜底: 从播放落到非播放且位置在末尾 → 续到下一首并上播放器', () async {
      final h = _Harness(
        songs: [
          fakeSong(id: 1, name: 'A'),
          fakeSong(id: 2, name: 'B'),
        ],
      );
      addTearDown(h.dispose);

      h.playback.current = _view(
        trackId: BigInt.one,
        playing: true,
        positionMs: 200,
      );
      await h.coordinator.poll();

      h.playback.current = _view(
        trackId: BigInt.one,
        playing: false,
        positionMs: 1000,
      );
      await h.coordinator.poll();
      await pumpEventQueue();

      expect(h.queue.index, 1, reason: '列表循环续到下一首');
      expect(h.playback.plays.map((p) => p.trackId), [BigInt.two]);
      expect(h.queueChangedCalls, greaterThanOrEqualTo(1), reason: '面板要重排高亮');
      expect(h.coordinator.player!.trackId, BigInt.two);
      expect(h.coordinator.userStopped, isFalse);
    });

    test('顺序播放到队尾: 停在最后一首, 只通知队列重排, 不再取链', () async {
      final h = _Harness(songs: [fakeSong(id: 1), fakeSong(id: 2)], startAt: 1);
      addTearDown(h.dispose);
      h.queue.mode = PlayMode.sequence;

      h.playback.current = _view(
        trackId: BigInt.two,
        playing: true,
        positionMs: 200,
      );
      await h.coordinator.poll();
      final rebuilds = h.notifies;

      h.playback.current = _view(
        trackId: BigInt.two,
        playing: false,
        positionMs: 1000,
      );
      await h.coordinator.poll();
      await pumpEventQueue();

      expect(h.queue.index, 1);
      expect(h.playback.plays, isEmpty);
      expect(h.queueChangedCalls, greaterThanOrEqualTo(1));
      expect(h.notifies, greaterThan(rebuilds));
    });

    test('用户正在拖进度条时不做"播完"判定', () async {
      final h = _Harness(songs: [fakeSong(id: 1), fakeSong(id: 2)]);
      addTearDown(h.dispose);

      h.playback.current = _view(
        trackId: BigInt.one,
        playing: true,
        positionMs: 200,
      );
      await h.coordinator.poll();
      h.dragging = true;
      h.playback.current = _view(
        trackId: BigInt.one,
        playing: false,
        positionMs: 1000,
      );
      await h.coordinator.poll();
      await pumpEventQueue();

      expect(h.queue.index, 0, reason: '拖动期间不续播');
      expect(h.playback.plays, isEmpty);
    });

    test('原生 STATE_ENDED 与轮询共用临界区: 一次结束只处理一次', () async {
      final h = _Harness(songs: [fakeSong(id: 1), fakeSong(id: 2)]);
      addTearDown(h.dispose);
      h.playback.current = _view(trackId: BigInt.one, playing: true);

      h.coordinator.onNativeTrackEnded();
      h.coordinator.onNativeTrackEnded();
      await pumpEventQueue();

      expect(h.playback.plays.length, 1);
      expect(h.queue.index, 1);
    });

    test('引导态(心动模式): 下一首走 guideNext, 不被单曲循环钉住', () async {
      final h = _Harness(songs: [fakeSong(id: 1)]);
      addTearDown(h.dispose);
      h.queue.mode = PlayMode.repeatOne;
      h.guide = QueueGuide.heart;
      h.guideResults.add(fakeSong(id: 42, name: '心动推荐'));

      h.coordinator.onNativeTrackEnded();
      await pumpEventQueue();

      expect(h.playback.plays.single.trackId, BigInt.from(42));
      expect(h.playback.plays.single.title, '心动推荐');
    });

    test('引导态续不到新歌: 停在当前这首并通知队列重排', () async {
      final h = _Harness(songs: [fakeSong(id: 1)]);
      addTearDown(h.dispose);
      h.guide = QueueGuide.fm;
      h.guideResults.add(null);

      h.coordinator.onNativeTrackEnded();
      await pumpEventQueue();

      expect(h.playback.plays, isEmpty);
      expect(h.queueChangedCalls, 1);
    });

    test('睡眠定时「播完这首」到点: 这一曲播完就停, 不续播', () async {
      var clock = DateTime(2026, 1, 1, 23, 0);
      final timer = SleepTimer(now: () => clock);
      final h = _Harness(
        songs: [fakeSong(id: 1), fakeSong(id: 2)],
        sleepTimer: timer,
      );
      addTearDown(h.dispose);
      timer.start(
        duration: const Duration(minutes: 15),
        mode: SleepTimerMode.finishCurrentSong,
      );

      h.playback.current = _view(
        trackId: BigInt.one,
        playing: true,
        positionMs: 200,
      );
      await h.coordinator.poll();
      clock = clock.add(const Duration(minutes: 16));
      // 到点但仍在播: 只打"等这首播完"标记, 不立刻停
      await h.coordinator.poll();
      expect(timer.pendingFinish, isTrue);
      expect(h.playback.plays, isEmpty);

      h.playback.current = _view(
        trackId: BigInt.one,
        playing: false,
        positionMs: 1000,
      );
      await h.coordinator.poll();
      await pumpEventQueue();

      expect(timer.fired, isTrue);
      expect(h.playback.plays, isEmpty, reason: '到点后不再取下一首');
      expect(h.queue.index, 0);
    });
  });

  group('起播 / 取链错误分支', () {
    test('取不到直链: 提示一次并自动跳过到下一首', () async {
      final h = _Harness(
        songs: [
          fakeSong(id: 1, name: 'A'),
          fakeSong(id: 2, name: 'B'),
        ],
      );
      addTearDown(h.dispose);
      api.urlByTrack['1'] = null; // 这首拿不到直链(会员/版权)

      await h.coordinator.playSong(fakeSong(id: 1, name: 'A'));
      await pumpEventQueue();

      expect(h.errors.length, 1);
      expect(h.errors.single, contains('没有可用直链'));
      expect(h.playback.plays.single.trackId, BigInt.two);
      expect(h.queue.index, 1);
      expect(h.queueChangedCalls, greaterThanOrEqualTo(1));
    });

    test('取链抛错: 转成友好文案, 队列绕一圈后停下', () async {
      final h = _Harness(songs: [fakeSong(id: 1)]);
      addTearDown(h.dispose);
      api.songUrlError = rust.FfiError(
        kind: 'network',
        retryable: false,
        detail: 'os error 104',
      );

      await h.coordinator.playSong(fakeSong(id: 1));
      await pumpEventQueue();

      expect(h.errors.single, contains('网络不稳定'));
      expect(h.playback.plays, isEmpty);
    });

    test('整队不可播(playable=false): 不取链、不播放, 只重建一次', () async {
      final h = _Harness(
        songs: [
          fakeSong(id: 1, playable: false),
          fakeSong(id: 2, playable: false),
        ],
      );
      addTearDown(h.dispose);

      await h.coordinator.playSong(fakeSong(id: 1, playable: false));
      await pumpEventQueue();

      expect(api.songUrlCalls, isEmpty);
      expect(h.playback.plays, isEmpty);
      expect(h.errors, isEmpty, reason: '无版权曲目静默跳过, 不连环弹窗');
      expect(h.notifies, greaterThan(0));
    });

    test('自动续播跳过 VIP 曲目: 静默跳过并整轮提示一次', () async {
      settings.skipVipSongs = true;
      final h = _Harness(
        songs: [
          fakeSong(id: 1, name: 'VIP 曲', vip: true),
          fakeSong(id: 2, name: '免费曲'),
        ],
      );
      addTearDown(h.dispose);

      await h.coordinator.playSong(fakeSong(id: 1, name: 'VIP 曲', vip: true));
      await pumpEventQueue();

      expect(h.playback.plays.single.trackId, BigInt.two);
      expect(h.toasts.single, contains('已跳过 1 首 VIP'));

      // 用户亲手点的那一首必须播(官方也是给前 30s 试听)
      final h2 = _Harness(songs: [fakeSong(id: 1, name: 'VIP 曲', vip: true)]);
      addTearDown(h2.dispose);
      await h2.coordinator.playSong(
        fakeSong(id: 1, name: 'VIP 曲', vip: true),
        explicit: true,
      );
      await pumpEventQueue();
      expect(h2.playback.plays.single.trackId, BigInt.one);
      expect(h2.toasts, isEmpty);
    });

    test('预取的下一首直链一次性使用: 换曲时不再重复取链', () async {
      final h = _Harness(
        songs: [fakeSong(id: 1), fakeSong(id: 2), fakeSong(id: 3)],
      );
      addTearDown(h.dispose);

      await h.coordinator.playSong(fakeSong(id: 1));
      await pumpEventQueue();
      expect(api.songUrlCalls, [BigInt.one, BigInt.two], reason: '起播后顺手预取下一首');

      // 正常链路: 队列已定位到第二首再起播(预取的那条直链被用掉)
      h.queue.jumpTo(1);
      await h.coordinator.playSong(fakeSong(id: 2));
      await pumpEventQueue();
      expect(api.songUrlCalls, [
        BigInt.one,
        BigInt.two,
        BigInt.from(3),
      ], reason: '第二首走预取, 第三次取链是给第三首预取');
      expect(h.playback.plays.map((p) => p.trackId), [BigInt.one, BigInt.two]);
    });

    test('取链成功: 直链交给播放器, 并按曲目记一次播放历史', () async {
      final h = _Harness(songs: [fakeSong(id: 1)]);
      addTearDown(h.dispose);
      api.defaultUrl = 'http://m801.music.126.net/a.mp3';

      await h.coordinator.playSong(fakeSong(id: 1));
      await pumpEventQueue();

      expect(h.playback.plays.single.url, 'http://m801.music.126.net/a.mp3');
      expect(api.songUrlCalls, contains(BigInt.one));
      expect(h.errors, isEmpty);
    });
  });

  group('现场恢复 / 按播放续播', () {
    test('恢复现场只摆播放条不播; 播放器空时轮询不清它; 按播放从保存位置续播', () async {
      final dir = (await Directory.systemTemp.createTemp('ncm-coord')).path;
      addTearDown(() => Directory(dir).delete(recursive: true));

      final songs = [fakeSong(id: 7, name: '恢复曲'), fakeSong(id: 8)];
      await PlaybackStateStore(dir).save(
        SavedPlayback(
          songs: songs,
          index: 0,
          positionMs: 42000,
          mode: PlayMode.repeatAll,
          libraryTitle: '正在播放',
        ),
      );

      final h = _Harness(dataDir: dir);
      addTearDown(h.dispose);
      await h.coordinator.restoreFromDisk(dir);
      await pumpEventQueue();

      expect(h.coordinator.player!.trackId, BigInt.from(7));
      expect(h.coordinator.player!.playing, isFalse, reason: '冷启动不自动吓人一跳');
      expect(h.queue.items.length, 2);
      expect(h.queue.index, 0);
      expect(h.restoredCalls, 1, reason: '页面态清零由 onRestored 做');
      expect(h.playback.plays, isEmpty);

      // 播放器实际为空: 不能把恢复出来的播放条覆盖掉
      h.playback.current = PlayerView.empty;
      await h.coordinator.poll();
      expect(h.coordinator.player!.trackId, BigInt.from(7));
      expect(h.coordinator.player!.positionMs, BigInt.from(42000));

      // 用户按播放 → 取链 + 从保存的位置续播
      await h.coordinator.toggle();
      await pumpEventQueue();
      expect(h.playback.plays.single.trackId, BigInt.from(7));
      expect(h.seeks.single, 42000.0);
      expect(h.coordinator.player!.playing, isTrue);
    });

    test('点击暂停 → 播放按下 → 分别走 pause/resume 并立刻落盘', () async {
      final dir = (await Directory.systemTemp.createTemp('ncm-coord')).path;
      addTearDown(() => Directory(dir).delete(recursive: true));
      final h = _Harness(songs: [fakeSong(id: 1)], dataDir: dir);
      addTearDown(h.dispose);
      // 播放态真相在协调器: 先 adopt 一个"正在播放", toggle 才会走 pause 而不是起播
      h.playback.current = _view(trackId: BigInt.one, playing: true);
      h.coordinator.adoptPlayer(h.playback.current);

      await h.coordinator.toggle();
      expect(h.playback.pauseCalls, 1);
      expect(h.coordinator.player!.playing, isFalse);

      await h.coordinator.toggle();
      expect(h.playback.resumeCalls, 1);
      expect(h.coordinator.player!.playing, isTrue);
      // 落盘是 unawaited 的真实文件 IO, 让它跑完
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = await PlaybackStateStore(dir).load();
      expect(state, isNotNull, reason: '暂停/继续必须立刻记住位置');
      expect(state!.songs.length, 1);
    });
  });
}

/// 平台通道类错误的最小替身(不依赖 flutter/services, 只让 state() 抛一次)。
class PlatformExceptionLike implements Exception {
  PlatformExceptionLike(this.message);
  final String message;
  @override
  String toString() => 'PlatformExceptionLike($message)';
}
