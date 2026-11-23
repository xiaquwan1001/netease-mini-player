import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app_settings.dart';
import '../audio_tuning.dart';
import '../cover_art.dart' show fetchImageBytes, httpsImageUrl, neteaseThumbUrl;
import '../net_retry.dart' show friendlyError, retryNetwork;
import '../playback.dart';
import '../playback_policy.dart' show shouldSkipVipSong;
import '../playback_state.dart';
import '../queue.dart';
import '../rust/api_all.dart' as rust;
import '../sleep_timer.dart';
import '../song_actions.dart' show SongActionSource;
import '../stream_note.dart' show StreamNote, publishStreamNote;
import 'lyric_controller.dart';

/// 播放协调器(从 main.dart 的 `_HomePageState` 搬出, 2026-11 拆壳 S4)。
///
/// 搬的是什么(逐行等价搬运, 不改时序/不改阈值):
/// - **播放态快照** [player]: 拆分前页面里的 `_player`。这是"当前播放态"的唯一
///   真相, 页面只读不写(改播放器的地方回灌给 [adoptPlayer])。
/// - **轮询**: 500ms 的 `_ticker` 与 [poll](原 `_pollPlayer`: 值不变不重建 /
///   换曲时同步响度增益 / 补测缓存 / 歌词跟随 / 播放中每 5s 落盘 / 播完兜底判定)。
/// - **续播**: [onNativeTrackEnded](原生 STATE_ENDED 即时通知) 与播完兜底共用
///   同一临界区, 自动续播与取链间隙([playSong] → [_resolveAndPlay] → 预取直链)。
/// - **现场**: [restoreFromDisk] / [clearSavedState] 与 5s 节流的落盘。
/// - **预取**: 下一首直链([_prefetchNextTrack], 4 分钟时效 + 一次性使用)与
///   通知栏封面字节([_artworkFor], 300ms 超时, 最多 8 张)。
///
/// 所有权边界(为什么有些东西仍留在页面):
/// - **队列** `PlayQueue` 由页面持有并【注入引用】, 这里不复制: 队列面板的
///   拖拽/删除/清空、`_sourceSongs`、播放条快照都直接读同一份对象。
/// - **歌词索引计算**仍归 [LyricController]: 这里只在 [poll] 里 `followPlayer`
///   喂位置; 歌词展开期的高频刷新是 LyricController 自己的 120ms ticker 回调
///   [poll], **ticker 只有一处**(不要在两边都 tick)。
/// - **需要 BuildContext 的东西**一律不进来: toast / 取封面主色 / 同步通知栏按钮
///   / seek / 起播后的列表标题, 全部由页面构造注入回调。
/// - **帧后投递契约不变**: `playerBarSlot` / `playerBarData` / `nowPlayingSongId`
///   仍在页面的 `_publishPlayerBar` 里 `addPostFrameCallback` 写, 这里不碰。
/// - **页面仍保留用户起播入口**(`_playFromList` / `_heartMode` / `_appendSongToQueue`
///   等): 它们同时改搜索态/列表态, 属于页面语义; 真正"上播放器"的动作走
///   [playSongsList] / [playSong] / [toggle]。
///
/// 状态变化一律 [notifyListeners]; 页面用 `addListener(→setState)` 订阅,
/// 与拆分前"每处状态变更各自 setState"的重建语义一一对应。
class PlaybackCoordinator extends ChangeNotifier {
  PlaybackCoordinator({
    required this.playback,
    required this.queue,
    required this.lyric,
    required this.dataDirOf,
    required this.libraryTitleOf,
    required this.toast,
    required this.toastError,
    required this.dragActive,
    required this.seekTo,
    required this.onPlaybackStarted,
    required this.onRestored,
    required this.guideOf,
    required this.guideNext,
    required this.queueChanged,
    required this.syncCoverPalette,
    required this.syncActionState,
    this.sleepTimer,
  });

  /// 播放门面(Android=Media3, 其它=Rust). 与页面共用**同一个实例**。
  final Playback playback;

  /// 播放队列(真相在页面, 这里只持有引用)。
  final PlayQueue<rust.SongDto> queue;

  /// 歌词状态机: 这里只在换曲时 `load`、轮询时 `followPlayer`。
  final LyricController lyric;

  /// Core 的 dataDir(未初始化时为 null); 现场落盘/清理用。
  final String? Function() dataDirOf;

  /// 当前"歌单浏览态"标题(现场文件里的 libraryTitle 字段; 恢复时不用)。
  final String? Function() libraryTitleOf;

  /// 普通提示(页面实现: mounted 判断 + `showToast`)。
  final void Function(String message) toast;

  /// 错误提示(页面实现: mounted 判断 + `showToast(..., isError: true)`)。
  final void Function(String message) toastError;

  /// 用户是否正在拖进度条: 拖动期间不做"播完"判定(原 `_dragMs != null`)。
  final bool Function() dragActive;

  /// 跳播放位置(页面持有拖动临时值 + 歌词跟随恢复, 所以留在页面)。
  final Future<void> Function(double ms) seekTo;

  /// 用一批曲目重置队列后的页面态(原 `_playSongsList` 里的 setState:
  /// `_libraryTitle='正在播放'` / `_queuePlaylistId` / `_playSource`)。
  final void Function(BigInt? playlistId, SongActionSource source)
  onPlaybackStarted;

  /// 启动恢复现场后页面的 `setState`(原 `_restorePlayback` 里同时清掉的
  /// 歌单浏览态三件: `_libraryTitle` / `_libraryPlaylistId` / `_queuePlaylistId`)。
  final void Function() onRestored;

  /// 当前引导态(心动模式/私人FM; 真相在 QueueSheetController)。
  ///
  /// 引导态下**播完一首不看 PlayMode**: 下一首由 provider 续（见 [guideNext]）。
  /// 用户反馈的现场就是反的 —— FM 只有 2 首, 播完以后被随机/单曲循环接管,
  /// 于是「切下一首列表不跟随刷新」「一直在两首里循环」。
  final QueueGuide Function() guideOf;

  /// 引导态下的"下一首"(页面实现: 顺序前进或续一批, 会把曲目追加进队列)。
  /// 返回 null = 没有更多, 停在当前这首。
  final Future<rust.SongDto?> Function() guideNext;

  /// 队列内容/当前下标被本类改过(自动续播、跳过曲目)时通知队列面板重排。
  ///
  /// PlayQueue 是普通对象不是 ChangeNotifier, 面板订阅的是 QueueSheetController
  /// ⇒ 续播后不叫这一声, 面板的高亮与「N 首」会停在旧状态(用户反馈
  /// 「切下一首时列表不跟随刷新」)。
  final void Function() queueChanged;

  /// 换曲后重算封面主色(原 `_syncCoverPalette`, 需要 setState)。
  final Future<void> Function() syncCoverPalette;

  /// 换曲后把红心/播放模式回传原生通知栏(原 `_syncActionState`)。
  final Future<void> Function() syncActionState;

  /// 睡眠定时(定时关闭): 到点判定挂在**既有**的 500ms 轮询与曲末处理上,
  /// 不另起一套轮询; null = 未接线(测试/无宿主)。
  final SleepTimer? sleepTimer;

  bool _disposed = false;

  // ---------------- 播放态快照(唯一真相) ----------------

  PlayerView? _player;

  /// 当前播放态快照(原页面 `_player`)。页面只读。
  PlayerView? get player => _player;

  /// 当前源能否**立即**精确 seek(桌面「边下边播」期 = false)。
  ///
  /// 注意: false **不等于不能跳**。P-10 方案 B 之后渐进期的 seek 会被 Rust 登记成
  /// 待跳([PlayerView.pendingSeekMs]), 缓存完成自动跳过去 ⇒ 进度条(播放条的
  /// [PlayerBarData.canSeek])一律可拖。这里保留的只是「立即生效」这一层信息,
  /// 给需要区分「已跳」与「已排队」的调用方/测试用。
  bool get canSeek => _player?.seekable ?? false;

  /// 轮询/暂停/seek 之后回灌快照(原 `setState(() => _player = state)`)。
  void adoptPlayer(PlayerView state) {
    if (_disposed) return;
    _player = state;
    notifyListeners();
  }

  // ---------------- 轮询 ----------------

  Timer? _ticker;

  /// 启动 500ms 轮询(调用点与拆分前 `initState` 末尾的 `Timer.periodic` 一致)。
  void startPolling() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => poll());
  }

  /// 轮询播放态(原 `_pollPlayer`)。歌词展开期间由 LyricController 的 120ms
  /// ticker 复用同一个 [poll], 全仓只有这一处"读播放器 + 追帧"的实现。
  Future<void> poll() async {
    PlayerView state;
    try {
      state = await playback.state();
    } catch (_) {
      return; // 播放后端未就绪(MediaController 连接中)时忽略
    }
    if (_disposed) return;
    // 恢复出来的"未加载现场": 播放器实际是空的, 别用它覆盖恢复出来的播放条
    if (_restoredFromDisk && state.trackId == null) return;
    final wasPlaying = _player?.playing ?? false;
    // 值没变就不重建: 暂停时每 500ms 一次无意义的整页重建,
    // 除了费电还会让 uiautomator 之类"等空闲"的工具永远等不到稳定帧。
    final prev = _player;
    if (prev == null ||
        prev.trackId != state.trackId ||
        prev.playing != state.playing ||
        prev.positionMs != state.positionMs ||
        prev.durationMs != state.durationMs ||
        prev.volume != state.volume ||
        // seek 能力随源变(边下边播期 = false), 变了就必须重建,
        // 否则进度条会一直停在旧的可用/禁用态(P-10)
        prev.seekable != state.seekable ||
        // 待跳登记/生效同样必须重建: 否则「已排队→mm:ss」与拇指位置会停在旧值,
        // 直到下一次位置变化才更新(P-10 方案 B 的 UI 面)。
        prev.pendingSeekMs != state.pendingSeekMs) {
      _player = state;
      notifyListeners();
    }
    // R2b: 曲目一换就按新曲目的响度给一次增益(未测则后台补测, 先按 0 dB 播)
    final playingId = state.trackId?.toInt();
    if (playingId != _loudnessAppliedTrackId) {
      _loudnessAppliedTrackId = playingId;
      // 歌词页背景跟随封面主色(node-vibrant 思路, 纯 Dart; 同 URL 有 LRU 缓存)
      unawaited(syncCoverPalette());
      // 通知栏红心按钮跟当前曲目走
      unawaited(syncActionState());
      if (playingId != null) {
        unawaited(
          applyLoudnessForTrack(
            playingId,
            streamUrl: _streamUrlByTrack[playingId],
          ),
        );
        unawaited(enforceCacheLimit(keepTrackId: playingId));
      }
    }
    // Android: 边听边存要整首存完才有"完整缓存 span", 所以播放中每 20s 补测一次
    if (playingId != null &&
        AppSettings.instance.loudnessNormalize &&
        !hasLoudnessGain(playingId)) {
      final now = DateTime.now();
      final last = _lastLoudnessRetry;
      if (last == null || now.difference(last) > const Duration(seconds: 20)) {
        _lastLoudnessRetry = now;
        unawaited(
          applyLoudnessForTrack(
            playingId,
            streamUrl: _streamUrlByTrack[playingId],
          ),
        );
      }
    }
    // 睡眠定时: 用同一份播放态心跳更新剩余时间, 并在到点(立刻停/播完这首)时
    // 通过 SleepTimer.onExpire 触发"停播放 + 退出"。不新起轮询。
    sleepTimer?.onPlaybackTick(playing: state.playing);
    // 通知栏图标自愈(P-02): 定时幂等重推一次红心/模式。
    // 值没变时 Playback.setActionState 直接短路(不跨通道/不刷新通知), 所以这里只是
    // 一次内存比较; 上一次推送失败(服务未就绪)或原生侧状态被重置时, 靠它自愈。
    _maybeSyncActionState();
    // 位置/播放中两个高频 notifier + 高亮行(顺序与条件由控制器保持原样)
    lyric.followPlayer(state);
    // 状态记忆: 播放中每 5s 落一次盘(暂停/换曲时会另有 force 落盘)
    if (state.playing) _persist();
    if (_looksEnded(wasPlaying, state)) {
      await _onTrackEnded();
    }
  }

  /// 上一次定时重推通知栏按钮状态的时间(节流: 每 5s 最多一次, 与落盘节流同口径)
  DateTime? _lastActionStateSync;

  /// 节流版 syncActionState: 真正的幂等判断在 Playback.setActionState 里(值未变不跨通道)
  void _maybeSyncActionState() {
    final now = DateTime.now();
    final last = _lastActionStateSync;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastActionStateSync = now;
    unawaited(syncActionState());
  }

  /// 播完判定: 从播放态落到非播放态, 且位置已在末尾附近.
  /// Media3/rodio 都不保证把 "ENDED" 送到 UI 层, 所以用轮询兜底.
  bool _looksEnded(bool wasPlaying, PlayerView s) {
    if (userStopped || _advancing || dragActive() || !wasPlaying || s.playing) {
      return false;
    }
    if (s.durationMs == BigInt.zero) return false;
    return s.positionMs + BigInt.from(800) >= s.durationMs;
  }

  // ---------------- 续播 ----------------

  /// 用户主动停止后不再自动续播(原 `_userStopped`)
  bool userStopped = false;

  /// 续播临界区: 防止一次结束被处理两遍(轮询 500ms + 异步取链)
  bool _advancing = false;

  /// 原生 STATE_ENDED → 队列续播(与轮询兜底共用 [_onTrackEnded] 的临界区)
  void onNativeTrackEnded() {
    if (_advancing) return;
    unawaited(_onTrackEnded());
  }

  Future<void> _onTrackEnded() async {
    if (_advancing) return;
    _advancing = true;
    try {
      final timer = sleepTimer;
      if (timer != null) {
        // 「播完这首」: 到点的这一曲播完就停, 不再续播下一首。
        // 已经由 poll 的 tick 触发过(fired)时 onTrackEnded 是空操作, 同样不续播。
        timer.onTrackEnded();
        if (timer.fired) {
          if (!_disposed) notifyListeners();
          return;
        }
      }
      // 引导态(心动模式/私人FM): 下一首由 provider 续播, 不受 PlayMode 约束。
      // 以前这里一律走 queue.onEnded() ⇒ 随机播放会打乱 FM 的顺序、单曲循环
      // 会把它钉成一首歌循环(用户反馈 4/5)。
      final next = guideOf() == QueueGuide.none
          ? queue.onEnded()
          : await guideNext();
      if (next == null) {
        // 顺序播放到队尾 / 引导态续不到新歌: 停在最后一首
        queueChanged();
        if (!_disposed) notifyListeners();
        return;
      }
      // 下标/队列已经变了(引导态还可能追加了一批): 队列面板要跟着重排
      queueChanged();
      await playSong(next);
    } finally {
      _advancing = false;
    }
  }

  // ---------------- 起播 ----------------

  /// 用一批曲目重置队列并从 [index] 开始播放(专辑/播客/每日推荐/最近听过共用).
  /// [playlistId]: 来源歌单(歌单详情页"定位正在播放"用), 不传即非歌单队列。
  ///
  /// 这是 `PlaybackBridge.playSongs` 的绑定目标(main.dart 里接线一次)。
  Future<void> playSongsList(
    List<rust.SongDto> songs,
    int index, {
    BigInt? playlistId,
    SongActionSource source = SongActionSource.other,
  }) async {
    if (songs.isEmpty) return;
    final start = index.clamp(0, songs.length - 1);
    queue.setAll(songs, startAt: start);
    userStopped = false;
    onPlaybackStarted(playlistId, source);
    await playSong(songs[start], explicit: true);
  }

  /// 当前设置下这首歌要不要跳过(口径见 playback_policy.dart, 已单测)。
  bool _skipVip(rust.SongDto song) => shouldSkipVipSong(
    song,
    skipVipEnabled: AppSettings.instance.skipVipSongs,
  );

  /// 跳过取不到直链的曲目(会员/版权限制)与设置里要求跳过的 VIP 曲目, 最多绕队列一圈。
  ///
  /// VIP 跳过是用户自己开的策略, 所以静默跳过、整轮结束才提示一次 —— 否则自动续播
  /// 会连环弹窗(与无版权曲目的处理口径一致)。
  ///
  /// [explicit] = 用户主动点选的这一首: 「自动跳过 VIP」只约束自动续播/切歌,
  /// 用户亲手点的歌必须播(官方也是这么做的 —— 会员曲目能试听前 30s),
  /// 只有取链真的拿不到直链时才继续往后跳。
  Future<void> playSong(rust.SongDto song, {bool explicit = false}) async {
    userStopped = false;
    _restoredFromDisk = false;
    // 续播位置不在这里清: 由 `_takeResumePositionFor` 取走即清(否则 _resolveAndPlay 读不到)
    var allowVip = explicit;
    var attempts = 0;
    var skippedVip = 0;
    void reportSkipped() {
      if (skippedVip > 0 && !_disposed) {
        toast('已跳过 $skippedVip 首 VIP 歌曲(可在设置里关闭)');
      }
    }

    var target = song;
    while (true) {
      if (!allowVip && _skipVip(target)) {
        skippedVip += 1;
      } else if (await _resolveAndPlay(target)) {
        reportSkipped();
        _persist(force: true);
        return;
      }
      // 跳过只发生在非主动点选的曲目上; 一旦绕到下一首就回到"自动续播"口径
      allowVip = false;
      attempts += 1;
      if (attempts >= queue.items.length) {
        if (!_disposed) notifyListeners();
        reportSkipped();
        return;
      }
      final next = queue.next();
      // 跳过不可播曲目时下标也动了: 面板高亮要跟上, 否则「正在播放」指在别的行
      queueChanged();
      if (next == null) return;
      target = next;
    }
  }

  /// 预取的下一首直链(曲目 id → 直链 + 档位 + 取得时间)。
  ///
  /// 为什么预取: 播完一首再去取链(数百毫秒)+ 让播放器重新 prepare, 表现为
  /// 连续播放每首之间都"卡一下"。提前把下一条直链拿到手, 换曲就只剩播放器
  /// 自己的缓冲。直链有时效(约几分钟到几十分钟), 所以带时间戳, 超过 4 分钟不用。
  /// `note` 随直链一起存: 试听/降级是要在播放条上说的, 预取命中时不能丢。
  final Map<int, ({String url, String level, DateTime at, StreamNote? note})>
  _prefetchedUrls =
      <int, ({String url, String level, DateTime at, StreamNote? note})>{};

  /// 取出可用的预取直链(一次性: 用过就删, 避免复用过期地址)
  ({String url, StreamNote? note})? _takePrefetchedUrl(
    int trackId,
    String level,
  ) {
    final hit = _prefetchedUrls.remove(trackId);
    if (hit == null) return null;
    if (hit.level != level) return null;
    if (DateTime.now().difference(hit.at) > const Duration(minutes: 4)) {
      return null;
    }
    return (url: hit.url, note: hit.note);
  }

  /// 后台预取"下一首"的直链(随机/单曲循环没有可预知的下一首, 直接跳过)。
  void _prefetchNextTrack() {
    // 引导态下"下一首"是顺序的下一格(随机/单曲循环的 peekNext 在这里恒为 null)
    final next = guideOf() == QueueGuide.none
        ? queue.peekNext()
        : queue.peekSequential();
    if (next == null || !next.playable) return;
    final id = next.id.toInt();
    if (_prefetchedUrls.containsKey(id)) return;
    final level = AppSettings.instance.audioLevel;
    unawaited(() async {
      try {
        // 带上歌曲上下文: 插件侧要用它拼上游 musicInfo(name/singer 缺了, 关键词系脚本取不到链);
        // 内置 provider 不看这些字段。
        final stream = await rust.songUrl(
          trackId: next.id,
          level: level,
          name: next.name,
          singer: next.artist,
          albumName: next.album,
          interval: next.durationMs ~/ BigInt.from(1000),
        );
        final url = stream.url;
        if (url == null || url.isEmpty) return;
        _prefetchedUrls[id] = (
          url: url,
          level: level,
          at: DateTime.now(),
          note: StreamNote.fromStream(stream),
        );
        if (_prefetchedUrls.length > 8) {
          _prefetchedUrls.remove(_prefetchedUrls.keys.first);
        }
      } catch (_) {
        // 预取失败无所谓: 真正换曲时还会走一次正常取链
      }
    }());
  }

  /// 通知栏/锁屏封面缓存(按已经按档位裁好的 URL 存, 最多 8 张)。
  final Map<String, Uint8List> _notificationArtwork = <String, Uint8List>{};

  /// 取当前播放内容的封面字节给系统通知用(播客/歌曲/电台都走 coverUrl)。
  ///
  /// 超时 300ms 就放弃: 封面是锦上添花, 绝不能为了它把播放拖慢(用户要求
  /// "总是乐观播放已经得到的片段")。UI 上刚显示过的封面通常已在
  /// cover_art.dart 的字节 LRU 里, 这条 await 实际是微任务级别。
  Future<Uint8List?> _artworkFor(rust.SongDto song) async {
    final url = song.coverUrl;
    if (url == null || url.isEmpty) return null;
    final key = neteaseThumbUrl(httpsImageUrl(url), width: 512, height: 512);
    final cached = _notificationArtwork[key];
    if (cached != null) return cached;
    try {
      final bytes = await fetchImageBytes(key)
          .timeout(const Duration(milliseconds: 300));
      if (_notificationArtwork.length >= 8) {
        _notificationArtwork.remove(_notificationArtwork.keys.first);
      }
      _notificationArtwork[key] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// 取链 + 上播放器(原 `_resolveAndPlay`)。
  ///
  /// 取链优先用预取结果, 没有才真的去取(retryNetwork: 移动网络切网偶发
  /// connection reset, 取链幂等所以值得重试)。
  Future<bool> _resolveAndPlay(rust.SongDto song) async {
    // 没版权的曲目连取链都不用试; 自动续播时静默跳过(点列表才提示, 否则一路弹窗)
    if (!song.playable) return false;
    // 续播位置的影份: 取出后若 play 抱错要回写(catch 看不到 try 内变量, 故提到 try 外)。
    int resumeTakenMs = 0;
    BigInt? resumeTakenId;
    try {
      // 先用预取的直链(有就用, 省掉几百毫秒); 没有才真的去取。
      final level = AppSettings.instance.audioLevel;
      final prefetched = _takePrefetchedUrl(song.id.toInt(), level);
      String? url = prefetched?.url;
      var note = prefetched?.note;
      if (url == null) {
        // 移动网络切网时会偶发 connection reset, 取链是幂等的, 值得重试
        final stream = await retryNetwork(
          () => rust.songUrl(
            trackId: song.id,
            level: level,
            name: song.name,
            singer: song.artist,
            albumName: song.album,
            interval: song.durationMs ~/ BigInt.from(1000),
          ),
        );
        url = stream.url;
        // 试听片段 / 静默降级 如实带出来(方案 A: 信息无损)
        note = StreamNote.fromStream(stream);
      }
      if (url == null) {
        // 没拿到直链 ⇒ 清掉提示(不能让上一条曲目的「试听」标签挂在别的曲子上)
        publishStreamNote(null, null);
        if (!_disposed) {
          toastError('《${song.name}》没有可用直链(会员曲目需先登录), 已跳过');
        }
        return false;
      }
      // Android 的响度均衡要靠这条直链去 Media3 的 SimpleCache 里找缓存文件;
      // 注意必须用**播放时实际用的**URL(playback.play 会把 http 升级成 https),
      // 否则 SimpleCache 的 key 对不上, 永远找不到缓存文件.
      final playingId = song.id.toInt();
      final cacheKeyUrl = preferHttpsStreamUrl(url);
      _streamUrlByTrack[playingId] = cacheKeyUrl;
      if (_streamUrlByTrack.length > 64) {
        _streamUrlByTrack.remove(_streamUrlByTrack.keys.first);
      }
      // 播放条上的「试听 mm:ss / 已降级 极高」提示(只读展示, 不参与播放控制)
      publishStreamNote(song.id, note);
      // 恢复现场的续播位置: 取一次就清(F7: 下次打开按播放要从记住的位置起, 不是 0)。
      // 取之前先影一份: play 抛错时回写, 别让一次失败把记忆位置静默清掉(审计 P2, 2026-11-23)。
      resumeTakenMs = _resumeAfterPlayMs;
      resumeTakenId = _resumeAfterPlayTrackId;
      final resumeMs = _takeResumePositionFor(song.id);
      final state = await playback.play(
        trackId: song.id,
        url: url,
        title: song.name,
        artist: song.artist,
        // 边下边播(桌面)时解码器拿不到总时长, 进度条用接口时长兜底
        durationMs: song.durationMs,
        // 通知栏图标 = 当前播放内容的封面(歌曲/播客统一走 coverUrl)
        artwork: await _artworkFor(song),
        // Android: 直接按这个位置起播(MediaItem 的起播位置, 不依赖 seek 通道的时序)
        startPositionMs: resumeMs > 0 ? BigInt.from(resumeMs) : null,
      );
      if (_disposed) return true;
      adoptPlayer(state);
      // 桌面(Rust)没有起播位置参数 ⇒ 起播后 seek 到同一位置;
      // Android 的起播位置已随 play(positionMs) 交给 ExoPlayer(setMediaItem 后、prepare 前),
      // 补 seek 反而可能把已前进几十毫秒的进度回拨 ⇒ Android 分支跳过(审计 P2, 2026-11-23)。
      if (resumeMs > 0 && !_disposed && !playback.isAndroid) {
        await seekTo(resumeMs.toDouble());
      }
      // 立刻按这首的响度给一次增益(未测到就先 0 dB, 轮询里会再补一次)
      _loudnessAppliedTrackId = playingId;
      unawaited(applyLoudnessForTrack(playingId, streamUrl: cacheKeyUrl));
      // 本地播放历史(未登录/离线时"最近听过"的来源); 失败不影响播放
      unawaited(rust.rememberPlay(song: song).catchError((_) => false));
      unawaited(lyric.load(song.id));
      // 播放已经起来了, 顺手把下一首的直链拿到手(让连续播放不再每首卡一下)
      _prefetchNextTrack();
      return true;
    } catch (e) {
      // 播放没起来 ⇒ 影份回写, 下次按播放仍从记忆位置续(不能静默丢, 审计 P2)
      if (resumeTakenId != null && resumeTakenMs > 0) {
        _resumeAfterPlayMs = resumeTakenMs;
        _resumeAfterPlayTrackId = resumeTakenId;
      }
      if (_disposed) return false;
      toastError(friendlyError(e));
      return false;
    }
  }

  // ---------------- 播放/暂停/停止 ----------------

  /// 播放条"播放/暂停"(原 `_toggle`)。启动时恢复的现场 / 空播放器 → 按播放
  /// 等于"从保存的位置续播这一首"。
  Future<void> toggle() async {
    if (_restoredFromDisk || _player?.trackId == null) {
      final song = queue.current;
      if (song != null) {
        _restoredFromDisk = false;
        // 续播位置不在这里 seek: 统一在 `_resolveAndPlay` 取(`_takeResumePositionFor`),
        // 这样任何起播路径都吃得到, 不必每处记得再 seek 一次。
        await playSong(song, explicit: true);
        return;
      }
    }
    final playing = _player?.playing ?? false;
    final state = playing ? await playback.pause() : await playback.resume();
    if (_disposed) return;
    adoptPlayer(state);
    // 状态记忆: 暂停/继续都立刻记一次位置(退出时最多差 5s)
    _persist(force: true);
  }

  /// 清空队列后停播(原 `_stopAfterQueueEmpty` 里的 stop 部分)。
  /// 播放后端未就绪时忽略: 队列已经是空, UI 保持一致。
  Future<void> stopPlayback() async {
    try {
      final state = await playback.stop();
      adoptPlayer(state);
    } catch (_) {}
  }

  // ---------------- 现场恢复 / 落盘 ----------------

  /// 启动时从 play_state.json 恢复了上次的队列/曲目(尚未真正加载到播放器)。
  /// 这段时间里轮询到"播放器空"不能把恢复出来的播放条清掉; 用户按播放才真正续播。
  bool _restoredFromDisk = false;

  /// 恢复出来的续播位置(毫秒) + 它属于哪首: 用户按播放时**只**对这首生效, 且只取一次。
  ///
  /// 为什么要记 id: 恢复后用户可能直接从搜索另点一首, 那个位置不能套到新曲上。
  int _resumeAfterPlayMs = 0;
  BigInt? _resumeAfterPlayTrackId;

  /// 取出并清空"恢复现场的续播位置": 只对 [trackId] 这首有效, 其余返回 0。
  int _takeResumePositionFor(BigInt trackId) {
    final ms = _resumeAfterPlayMs;
    final id = _resumeAfterPlayTrackId;
    _resumeAfterPlayMs = 0;
    _resumeAfterPlayTrackId = null;
    if (ms <= 0 || id != trackId) return 0;
    return ms;
  }

  /// 上次落盘播放现场的时间(节流: 每 5s 最多一次, 避免每 500ms 轮询都写文件)
  DateTime? _lastStateSave;

  /// 状态记忆: 恢复上次退出时的播放现场(队列 + 当前曲 + 位置)。
  ///
  /// 只恢复"看起来的样子", 不自动播放 —— 用户可能只是在后台/耳机里退出的,
  /// 重开 App 吓一跳不合适。点播放才真正取链, 并从保存的位置续播。
  Future<void> restoreFromDisk(String dataDir) async {
    if (dataDir.isEmpty || queue.items.isNotEmpty) return;
    final saved = await PlaybackStateStore(dataDir).load();
    if (saved == null || saved.songs.isEmpty || _disposed) return;
    if (queue.items.isNotEmpty) return; // 期间用户已经点歌了, 不覆盖
    queue.setAll(saved.songs, startAt: saved.index);
    queue.mode = saved.mode;
    final song = saved.current;
    _player = PlayerView(
      trackId: song.id,
      playing: false,
      positionMs: BigInt.from(saved.positionMs),
      durationMs: song.durationMs,
      volume: 1.0,
    );
    _restoredFromDisk = true;
    // F7: 记住续播位置与它属于哪首 —— 用户下个动作若是"播放", 就从这里起播(不是 0)
    _resumeAfterPlayMs = saved.positionMs;
    _resumeAfterPlayTrackId = song.id;
    // 事件通知: 恢复出来的曲目不会走 `_playSong`(用户可能一直不点播放),
    // 歌词/歌曲信息就永远停在「暂无 / 信息不可用」。开 App 即提前取一次
    // (幂等, 失败只进 `LyricController.error`, 点播放时还会再试)。
    unawaited(lyric.load(song.id));
    // 只恢复队列与播放现场, **不进"歌单浏览态"**: 那是搜索页里的一个显示
    // 状态, 冷启动时把它填上会让 App 一开就停在"正在播放"列表(用户反馈)。
    // 队列本身仍可从播放条/播放队列看到。页面态的清零由 onRestored 的 setState 做
    // (与拆分前同一个 setState, 不额外多一次重建)。
    if (!_disposed) onRestored();
  }

  /// 状态记忆: 落盘当前现场(节流 5s; [force] 用于换曲/暂停等必须立刻记住的时刻)。
  void _persist({bool force = false}) {
    final dir = dataDirOf();
    if (dir == null || dir.isEmpty || _restoredFromDisk) return;
    final songs = queue.items;
    if (songs.isEmpty) return;
    final now = DateTime.now();
    final last = _lastStateSave;
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastStateSave = now;
    unawaited(
      PlaybackStateStore(dir).save(
        SavedPlayback(
          songs: songs,
          index: queue.index < 0 ? 0 : queue.index,
          positionMs: _player?.positionMs.toInt() ?? 0,
          mode: queue.mode,
          libraryTitle: libraryTitleOf(),
        ),
      ),
    );
  }

  /// 队列被清空时抹掉现场(否则下次启动会恢复出一个空壳播放条)。
  Future<void> clearSavedState() async {
    final dir = dataDirOf();
    if (dir == null || dir.isEmpty) return;
    await PlaybackStateStore(dir).clear();
  }

  // ---------------- 响度增益簿记(轮询里用) ----------------

  /// 已经为哪首曲目应用过响度增益(避免每 500ms 轮询都重算)
  int? _loudnessAppliedTrackId;

  /// 最近取到的直链(曲目 id -> url): Android 的响度测量要靠它去 SimpleCache 里找缓存文件
  final Map<int, String> _streamUrlByTrack = <int, String>{};

  /// 上一次"补测响度"的时间(Android 的缓存文件要整首存完才能测, 所以播放中隔一会儿重试)
  DateTime? _lastLoudnessRetry;

  /// 设置里改了响度参数时, 页面已重新应用增益 → 标记成"没换曲"(原
  /// `_loudnessAppliedTrackId = id`)。
  void markLoudnessApplied(int? trackId) => _loudnessAppliedTrackId = trackId;

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }
}
