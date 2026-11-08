import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/album_preview.dart';
import 'src/similar_sheet.dart';
import 'src/user_list_page.dart';
import 'src/app_settings.dart';
import 'src/audio_tuning.dart';
import 'src/artist_page.dart';
import 'src/auth.dart';
import 'src/cover_art.dart';
import 'src/detail_page.dart';
import 'src/discover.dart';
import 'src/feed_view.dart';
import 'src/lyric.dart';
import 'src/word_lyric_view.dart';
import 'src/library_view.dart';
import 'src/medal_wall.dart';
import 'src/messages_page.dart';
import 'src/new_release_page.dart';
import 'src/mine_view.dart';
import 'src/net_retry.dart';
import 'src/play_queue_sheet.dart';
import 'src/playback.dart';
import 'src/queue.dart';
import 'src/platform.dart';
import 'src/recommend_view.dart';
import 'src/search_landing.dart';
import 'src/search_exact_bar.dart';
import 'src/search_results.dart';
import 'src/search_suggest.dart';
import 'src/settings_account_page.dart';
import 'src/settings_view.dart';
import 'src/song_actions.dart';
import 'src/song_share.dart';
import 'src/song_tile.dart';
import 'src/song_wiki.dart';
import 'src/theme.dart';
import 'src/vip_page.dart';
import 'src/rust/api.dart' as rust;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MiniNcmApp());
}

String _fmt(BigInt ms) {
  final total = (ms ~/ BigInt.from(1000)).toInt();
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

const _modeIcons = {
  PlayMode.repeatAll: Icons.repeat,
  PlayMode.repeatOne: Icons.repeat_one,
  PlayMode.sequence: Icons.playlist_play,
  PlayMode.shuffle: Icons.shuffle,
};

const _modeLabels = {
  PlayMode.repeatAll: '列表循环',
  PlayMode.repeatOne: '单曲循环',
  PlayMode.sequence: '顺序播放',
  PlayMode.shuffle: '随机播放',
};

/// 全局动作回调宿主: MaterialApp.builder 里包一层 AppActions,
/// 这样搜索结果/详情页/底部面板等所有路由里的 "..." 菜单都能拿到同一套回调。
final ValueNotifier<SongActionHost?> _actionsHost =
    ValueNotifier<SongActionHost?>(null);

class MiniNcmApp extends StatelessWidget {
  const MiniNcmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final settings = AppSettings.instance;
        return MaterialApp(
          title: '轻音 MiniNCM',
          // 桌面版 debug 构建的 DEBUG 斜标会压住 AppBar 右上角的歌单/账号按钮
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          // R6: 深色 + OLED 开关 ⇒ 纯黑基底(见 src/theme.dart)
          darkTheme: buildDarkTheme(oled: settings.oledDark),
          themeMode: settings.themeMode,
          builder: (context, child) => MediaQuery(
            data: scaledMediaQuery(context, settings.textScale),
            // 动作回调挂在 Navigator 之上, pushed route 也能取到
            child: ValueListenableBuilder<SongActionHost?>(
              valueListenable: _actionsHost,
              builder: (_, host, inner) =>
                  host == null ? inner! : AppActions(host: host, child: inner!),
              child: child ?? const SizedBox.shrink(),
            ),
          ),
          home: const HomePage(),
        );
      },
    );
  }
}

/// 根页面的返回键优先级, 从高到低:
/// 歌词展开 → 收起歌词; 非首 tab → 回搜索 tab; 歌单浏览态 → 退出浏览;
/// 都没有(栈底 + 无二级态) → 交还系统, 由系统退出 App.
///
/// 纯函数, 便于单测(返回键的分支比 UI 更容易出错).
enum HomeBackAction {
  collapseLyrics,
  resetTab,
  closeLibrary,
  exitApp,
}

HomeBackAction resolveHomeBackAction({
  required bool showLyrics,
  required int tab,
  required bool libraryOpen,
}) {
  if (showLyrics) return HomeBackAction.collapseLyrics;
  if (tab != 0) return HomeBackAction.resetTab;
  if (libraryOpen) return HomeBackAction.closeLibrary;
  return HomeBackAction.exitApp;
}

/// 把 [HomeBackAction] 接到系统返回键(Android 手势/返回键, 桌面 Esc)上.
///
/// 只有"栈底且无二级态"时 canPop=true 让系统退出, 其余一律拦下来先退一层;
/// 否则用户在歌词页/推荐页按返回会直接退出 App(审查 P0-7.1).
class HomeBackGuard extends StatelessWidget {
  const HomeBackGuard({
    super.key,
    required this.action,
    required this.onBack,
    required this.child,
  });

  final HomeBackAction action;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: action == HomeBackAction.exitApp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        onBack();
      },
      child: child,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _controller = TextEditingController();
  final _playback = Playback();
  final _auth = Auth();
  final _queue = PlayQueue<rust.SongDto>();
  final _lyricScroll = ScrollController();
  rust.InitInfo? _info;
  rust.SearchBundleDto? _bundle;
  PlayerView? _player;
  String? _error;

  /// 出错时可以一键重试的动作(搜索/打开歌单这类幂等操作)
  Future<void> Function()? _retryLast;
  bool _busy = false;
  Timer? _ticker;

  /// 用户主动停止后不再自动续播
  bool _userStopped = false;

  /// 拖动进度条时的临时值(避免每帧都 seek); _dragMax 在拖动开始时冻结,
  /// 否则自动续播换曲会让滑杆量程突跳, 把新曲目 seek 到末尾。
  double? _dragMs;
  double? _dragMax;

  /// 续播临界区: 防止一次结束被处理两遍(轮询 500ms + 异步取链)
  bool _advancing = false;

  // ---- 歌词 ----
  static const double _lyricItemExtent = 56;
  List<ParsedLyricLine> _lyricLines = const [];
  List<BigInt> _lyricTimes = const [];
  /// 纯文本歌词兜底(无时间轴): 逐行接口失败/返回空时用 [parseLrc] 从原始 LRC 里取。
  List<String>? _lyricPlain;
  BigInt? _lyricTrackId;
  String? _lyricError;
  int _lyricIndex = -1;
  bool _showLyrics = false;

  /// 歌词是否跟随播放自动滚动: 用户手动滑歌词时置 false, 点"定位"再置回 true
  bool _autoFollowLyric = true;

  /// 详情页歌词多选: 长按进入, 点行加/减选, 选中后右上角变成分享/取消
  final Set<int> _selectedLyricLines = <int>{};

  /// 逐字(karaoke)歌词数据; 有则优先用 [WordLyricView], 无则回落行级/纯文本链。
  List<WordLyricLineData> _wordLines = const [];

  /// 播放位置(毫秒)注入给 [WordLyricView]: 刷新只重建当前行, 不整页 setState。
  final ValueNotifier<int> _wordPositionMs = ValueNotifier<int>(0);

  /// 展开歌词时的高频位置刷新(~120ms); 收起必须停掉, 避免后台耗电。
  Timer? _lyricTicker;

  /// "我喜欢的音乐"里的曲目 id: 红心状态的唯一真相
  Set<BigInt> _liked = <BigInt>{};

  /// 歌单浏览态: 非空时列表显示这个歌单而不是搜索结果
  List<rust.SongDto> _library = const [];
  String? _libraryTitle;

  /// 当前浏览的歌单 id(心动模式要用 playlistId; 搜索态为 null)
  BigInt? _libraryPlaylistId;

  /// 当前播放队列的来源歌单 id(详情页"定位正在播放"用;
  /// 搜索/心动模式/推荐流等非歌单队列为 null)
  BigInt? _queuePlaylistId;

  /// "我喜欢的音乐"这个歌单的 id(懒解析: 从"我的"页点播时要用它标记队列来源)
  BigInt? _likedPlaylistId;

  /// 底部导航: 0 搜索 / 1 推荐 / 2 关注 / 3 我的 / 4 设置
  int _tab = 0;

  /// 已经打开过的 tab: 只有访问过的页面才进 IndexedStack(惰性构建),
  /// 之后一直保留 State —— 否则每次切 tab 都销毁重建子树,
  /// 图片 Widget 重新解析, 占位符会高频闪烁, 列表滚动位置也会丢
  final Set<int> _tabVisited = <int>{0};

  /// 搜索请求代次: 取消/重新搜索后旧请求的结果直接丢弃
  int _searchToken = 0;

  // ---- 搜索建议 / 历史 ----
  final _searchFocus = FocusNode();
  Timer? _suggestDebounce;
  List<rust.SuggestItem> _suggestions = const [];
  /// 精确实体命中(search_multimatch; orders 为空 = 无命中)
  rust.SearchExact? _exact;
  /// 纯关键词联想(mobile search_suggest; 卡片/实体都空时的兜底)
  List<String> _keywordSuggestions = const [];
  List<String> _searchHistory = const [];

  // ---- 搜索落地页(热词/推荐词) ----
  List<rust.HotSearchTerm> _hotTerms = const [];
  /// "猜你想搜": keyword 是真正要搜的词, reason 是官方给的推荐理由(只展示)
  String? _recommendedKeyword;
  String? _recommendedReason;
  bool _hotLoading = false;
  String? _hotError;

  rust.SongDto? get _current => _queue.current;

  /// 当前列表的原始曲目(歌单浏览优先)
  List<rust.SongDto> get _sourceSongs =>
      _libraryTitle != null ? _library : (_bundle?.songs ?? const <rust.SongDto>[]);

  /// 真正要显示/入队的曲目: 无版权且没收藏的直接不显示(与官方一致)
  List<rust.SongDto> get _visibleSongs => visibleSongs(_sourceSongs, _liked);

  /// 被隐藏的无版权曲目数量(列表顶部提示用)
  int get _hiddenUnplayable => hiddenUnplayableCount(_sourceSongs, _liked);

  @override
  void initState() {
    super.initState();
    // 通知栏/耳机键的上一首·下一首 → Dart 队列
    Playback.setSkipHandlers(onNext: _next, onPrevious: _previous);
    // R2/R5/R7: 设置里的播放参数变化时同步给 Rust 播放器
    AppSettings.instance.addListener(_onAudioSettingsChanged);
    // "..." 菜单的动作宿主在 Navigator 之上, 先放一份(登录态变化时再刷新)
    _actionsHost.value = _buildActionsHost();
    _searchFocus.addListener(_onSearchFocusChanged);
    _bootstrap();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollPlayer());
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAudioSettingsChanged);
    _ticker?.cancel();
    _suggestDebounce?.cancel();
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    _lyricTicker?.cancel();
    _lyricScroll.dispose();
    _wordPositionMs.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final dir = await _playback.dataDir();
      final info = await rust.init(dataDir: dir);
      await AppSettings.instance.load(info.dataDir);
      // 启动时把已保存的播放参数与缓存上限应用一次(默认值 = 不改变现状)
      unawaited(applyAudioTuning());
      unawaited(enforceCacheLimit());
      if (!mounted) return;
      setState(() => _info = info);
      _actionsHost.value = _buildActionsHost();
      // 本地历史和热词都依赖 init() 建立的 Core, 必须等初始化完成再拉
      unawaited(_loadSearchHistory());
      unawaited(_loadSearchLanding());
      // 已登录就把账号记进账号簿(老版本登录过的账号也能被记住)
      if (info.loggedIn) {
        unawaited(_syncAccount());
        unawaited(_loadLiked());
        unawaited(_resolveLikedPlaylistId());
      }
    } catch (e) {
      setState(() => _error = friendlyError(e));
    }
  }

  /// 播放参数变化时才真的调 FFI(设置页里每拖一格 Slider 都会 notifyListeners)
  AudioTuningRequest? _lastTuning;
  int? _lastCacheLimitMb;
  bool? _lastLoudnessNormalize;
  double? _lastLoudnessTarget;
  /// 已经为哪首曲目应用过响度增益(避免每 500ms 轮询都重算)
  int? _loudnessAppliedTrackId;

  /// 最近取到的直链(曲目 id -> url): Android 的响度测量要靠它去 SimpleCache 里找缓存文件
  final Map<int, String> _streamUrlByTrack = <int, String>{};

  /// 上一次"补测响度"的时间(Android 的缓存文件要整首存完才能测, 所以播放中隔一会儿重试)
  DateTime? _lastLoudnessRetry;

  void _onAudioSettingsChanged() {
    final settings = AppSettings.instance;
    // 响度均衡的开关/目标电平变化 ⇒ 已算好的每曲增益全部作废, 当前曲目重算
    final loudnessChanged = settings.loudnessNormalize != _lastLoudnessNormalize ||
        settings.loudnessTargetLufs != _lastLoudnessTarget;
    _lastLoudnessNormalize = settings.loudnessNormalize;
    _lastLoudnessTarget = settings.loudnessTargetLufs;
    if (loudnessChanged) {
      forgetLoudnessGain();
      final id = _player?.trackId?.toInt();
      if (id != null) {
        _loudnessAppliedTrackId = id;
        unawaited(applyLoudnessForTrack(id));
      }
      return;
    }
    final request = AudioTuningRequest.fromSettings(settings);
    if (request != _lastTuning) {
      _lastTuning = request;
      unawaited(applyAudioTuning());
    }
    if (settings.cacheLimitMb != _lastCacheLimitMb) {
      _lastCacheLimitMb = settings.cacheLimitMb;
      unawaited(enforceCacheLimit(keepTrackId: _player?.trackId?.toInt()));
    }
  }

  Future<void> _pollPlayer() async {
    PlayerView state;
    try {
      state = await _playback.state();
    } catch (_) {
      return; // 播放后端未就绪(MediaController 连接中)时忽略
    }
    if (!mounted) return;
    final wasPlaying = _player?.playing ?? false;
    // 值没变就不 setState: 暂停时每 500ms 一次无意义的整页重建,
    // 除了费电还会让 uiautomator 之类"等空闲"的工具永远等不到稳定帧。
    final prev = _player;
    if (prev == null ||
        prev.trackId != state.trackId ||
        prev.playing != state.playing ||
        prev.positionMs != state.positionMs ||
        prev.durationMs != state.durationMs ||
        prev.volume != state.volume) {
      setState(() => _player = state);
    }
    // R2b: 曲目一换就按新曲目的响度给一次增益(未测则后台补测, 先按 0 dB 播)
    final playingId = state.trackId?.toInt();
    if (playingId != _loudnessAppliedTrackId) {
      _loudnessAppliedTrackId = playingId;
      if (playingId != null) {
        unawaited(applyLoudnessForTrack(
          playingId,
          streamUrl: _streamUrlByTrack[playingId],
        ));
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
        unawaited(applyLoudnessForTrack(
          playingId,
          streamUrl: _streamUrlByTrack[playingId],
        ));
      }
    }
    if (state.positionMs != BigInt.from(_wordPositionMs.value)) {
      _wordPositionMs.value = state.positionMs.toInt();
    }
    _syncLyricIndex(state);
    if (_looksEnded(wasPlaying, state)) {
      await _onTrackEnded();
    }
  }

  /// 播完判定: 从播放态落到非播放态, 且位置已在末尾附近.
  /// Media3/rodio 都不保证把 "ENDED" 送到 UI 层, 所以用轮询兜底.
  bool _looksEnded(bool wasPlaying, PlayerView s) {
    if (_userStopped || _advancing || _dragMs != null || !wasPlaying || s.playing) return false;
    if (s.durationMs == BigInt.zero) return false;
    return s.positionMs + BigInt.from(800) >= s.durationMs;
  }

  Future<void> _onTrackEnded() async {
    if (_advancing) return;
    _advancing = true;
    try {
      final next = _queue.onEnded();
      if (next == null) {
        setState(() {}); // 顺序播放到队尾: 停在最后一首
        return;
      }
      await _playSong(next);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    final token = ++_searchToken;
    _suggestDebounce?.cancel();
    _searchFocus.unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _suggestions = const [];
      _exact = null;
      _keywordSuggestions = const [];
      // 搜索即离开歌单浏览态, 结果列表要保持"这一屏是什么"的唯一来源
      _library = const [];
      _libraryTitle = null;
      _libraryPlaylistId = null;
    });
    try {
      final result = await retryNetwork(
        () => rust.searchAll(keywords: keyword, limit: 20),
      );
      if (!mounted || token != _searchToken) return;
      setState(() => _bundle = result);
      // 搜索历史是本地记录, 失败不影响搜索结果
      try {
        final history = await rust.recordSearch(keyword: keyword);
        if (mounted) setState(() => _searchHistory = history);
      } catch (_) {}
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _error = friendlyError(e);
        _retryLast = _search;
      });
    } finally {
      if (mounted && token == _searchToken) setState(() => _busy = false);
    }
  }

  /// 显式取消: 清掉输入、上一轮结果、联想和错误, 回到搜索落地页
  void _clearSearch() {
    _searchToken += 1;
    _suggestDebounce?.cancel();
    _controller.clear();
    _searchFocus.unfocus();
    setState(() {
      _bundle = null;
      _suggestions = const [];
      _exact = null;
      _keywordSuggestions = const [];
      _error = null;
      _retryLast = null;
      _busy = false;
      _library = const [];
      _libraryTitle = null;
      _libraryPlaylistId = null;
    });
  }

  // ---------------- 搜索建议 / 历史 ----------------

  void _onSearchFocusChanged() {
    if (!mounted) return;
    if (!_searchFocus.hasFocus) {
      setState(() {
        _suggestions = const [];
        _exact = null;
        _keywordSuggestions = const [];
      });
    } else {
      // 重新获得焦点: 刷新历史(别处可能新增过)
      _loadSearchHistory();
      setState(() {});
    }
  }

  Future<void> _loadSearchHistory() async {
    try {
      final list = await rust.searchHistory();
      if (!mounted) return;
      setState(() => _searchHistory = list);
    } catch (_) {
      // 历史读不出来不影响主流程
    }
  }

  /// 搜索落地页的热词榜 + 默认/推荐搜索词. 两块互相独立, 失败不影响搜索.
  Future<void> _loadSearchLanding() async {
    if (mounted) setState(() => _hotLoading = true);
    try {
      // 热搜用 hotsearchlist(带服务端榜位/热度, 固定 20 条); 失败再退回老的热词接口
      List<rust.HotSearchTerm> hot;
      try {
        final detail = await retryNetwork(rust.hotSearchDetail);
        hot = [
          for (final it in detail)
            rust.HotSearchTerm(rank: it.rank, keyword: it.keyword),
        ];
        if (hot.isEmpty) hot = await retryNetwork(rust.hotSearch);
      } catch (_) {
        hot = await retryNetwork(rust.hotSearch);
      }
      if (!mounted) return;
      setState(() {
        _hotTerms = hot;
        _hotError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _hotError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _hotLoading = false);
    }
    try {
      final recommended = await rust.defaultSearch();
      if (!mounted) return;
      setState(() {
        _recommendedKeyword = recommended?.keyword;
        _recommendedReason = recommended?.showText;
      });
    } catch (_) {
      // 推荐词是锦上添花, 失败静默
    }
  }

  void _onQueryChanged(String value) {
    _suggestDebounce?.cancel();
    // 让"清空/取消"按钮随输入内容即时出现
    if (mounted) setState(() {});
    final q = value.trim();
    if (q.isEmpty) {
      setState(() {
        _suggestions = const [];
        _exact = null;
        _keywordSuggestions = const [];
      });
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      // 三个来源并行: 联想卡片(web) / 精确实体(multimatch) / 纯关键词(mobile)
      final exactFuture = _loadExact(q);
      final keywordsFuture = _loadSuggestKeywords(q);
      try {
        final items = await rust.searchSuggest(keywords: q);
        if (!mounted || _controller.text.trim() != q) return;
        setState(() => _suggestions = items);
      } catch (_) {
        // 建议是锦上添花, 失败静默
      }
      final exact = await exactFuture;
      final keywords = await keywordsFuture;
      if (!mounted || _controller.text.trim() != q) return;
      setState(() {
        _exact = exact;
        _keywordSuggestions = keywords;
      });
    });
  }

  Future<rust.SearchExact?> _loadExact(String q) async {
    try {
      final exact = await rust.searchExact(keywords: q);
      // orders 为空就是空命中伪装成 200, 当作没有
      return exact.orders.isEmpty ? null : exact;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _loadSuggestKeywords(String q) async {
    try {
      return await rust.searchSuggestKeywords(keywords: q);
    } catch (_) {
      return const [];
    }
  }

  /// DTO -> 精确实体条视图(空命中由 SearchExactBar 自己隐藏)
  SearchExactView _exactView(rust.SearchExact e) => SearchExactView(
        orders: e.orders,
        artists: [
          for (final a in e.artists)
            SearchExactArtist(id: a.id.toInt(), name: a.name, avatarUrl: a.avatarUrl),
        ],
        playlists: [
          for (final p in e.playlists)
            SearchExactPlaylist(
              id: p.id.toInt(),
              name: p.name,
              coverUrl: p.coverUrl,
              trackCount: p.trackCount.toInt(),
            ),
        ],
        podcasts: [
          for (final r in e.podcasts)
            SearchExactRadio(
              id: r.id.toInt(),
              name: r.name,
              coverUrl: r.coverUrl,
              djName: r.djName,
              programCount: r.programCount.toInt(),
            ),
        ],
      );

  Future<void> _openExactArtist(int id) async {
    for (final a in _exact?.artists ?? const <rust.Artist>[]) {
      if (a.id.toInt() != id) continue;
      await showArtistDetail(
        context,
        artistId: a.id,
        name: a.name,
        onPlaySongs: (songs, i) => _playSongsList(songs, i),
        onOpenAlbum: (albumId, name, cover) => showAlbumPreview(
          context,
          albumId: albumId,
          albumName: name,
          coverUrl: cover,
          onPlay: (songs, i) => _playSongsList(songs, i),
        ),
      );
      return;
    }
  }

  Future<void> _openExactPlaylist(int id) async {
    for (final p in _exact?.playlists ?? const <rust.Playlist>[]) {
      if (p.id.toInt() == id) {
        await _openPlaylist(p);
        return;
      }
    }
  }

  void _openExactRadio(int id) {
    for (final r in _exact?.podcasts ?? const <rust.PodcastRadio>[]) {
      if (r.id.toInt() == id) {
        _openPodcastRadio(r);
        return;
      }
    }
  }

  Future<void> _searchKeyword(String keyword) async {
    _controller.text = keyword;
    _controller.selection = TextSelection.collapsed(offset: keyword.length);
    setState(() {
        _suggestions = const [];
        _exact = null;
        _keywordSuggestions = const [];
      });
    await _search();
  }

  Future<void> _clearSearchHistory() async {
    try {
      await rust.clearSearchHistory();
      if (mounted) setState(() => _searchHistory = const []);
    } catch (_) {}
  }

  /// 用一批曲目重置队列并从 index 开始播放(专辑/播客/每日推荐/最近听过共用).
  /// playlistId: 来源歌单(歌单详情页"定位正在播放"用), 不传即非歌单队列。
  Future<void> _playSongsList(
    List<rust.SongDto> songs,
    int index, {
    BigInt? playlistId,
  }) async {
    if (songs.isEmpty) return;
    final start = index.clamp(0, songs.length - 1);
    _queue.setAll(songs, startAt: start);
    _userStopped = false;
    setState(() {
      _library = songs;
      _libraryTitle = '正在播放';
      _libraryPlaylistId = null;
      _queuePlaylistId = playlistId;
    });
    await _playSong(songs[start]);
  }

  // ---------------- 心动模式 / 每日推荐 / 播客 / 最近听过 / 封面预览 ----------------

  /// 心动模式: 以当前曲目为种子, 在当前歌单(0=不限定)里续播一队推荐.
  /// 网易云这个接口需要登录, 未登录会返回 [auth] 错误.
  Future<void> _heartMode({rust.SongDto? seed}) async {
    final current = seed ?? _current;
    final id = current?.id;
    if (id == null) {
      _toast('先播一首歌, 再开启心动模式');
      return;
    }
    setState(() => _busy = true);
    try {
      final songs = await retryNetwork(
        () => rust.heartModeSongs(
          songId: id,
          playlistId: _libraryPlaylistId ?? BigInt.zero,
          count: 30,
        ),
      );
      if (!mounted) return;
      final seen = <BigInt>{id};
      final list = <rust.SongDto>[?current];
      for (final s in songs) {
        if (s.playable && seen.add(s.id)) list.add(s);
      }
      if (list.length <= 1) {
        _toast('心动模式暂时没有推荐(登录后推荐更准)');
        return;
      }
      _queue.setAll(list, startAt: 0);
      _userStopped = false;
      setState(() {
        _library = list;
        _libraryTitle = '心动模式';
        _queuePlaylistId = null;
      });
      final next = _queue.next();
      if (next != null) await _playSong(next);
    } catch (e) {
      if (!mounted) return;
      _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _openDiscover() {
    showDiscoverPage(
      context,
      onPlaySongs: (songs, index) => _playSongsList(songs, index),
      onOpenPlaylist: (pl) => _openPlaylist(pl),
      onDislike: (song) => rust.dislikeRecommendSong(songId: song.id),
    );
  }

  /// 直接打开某个播客的详情页(推荐/我的页面的卡片点进来)
  void _openPodcastRadio(rust.PodcastRadio radio) {
    showPodcastDetail(
      context,
      radio: radio,
      onPlaySongs: (songs, index) => _playSongsList(songs, index),
    );
  }

  void _openRecent() {
    showRecentPage(
      context,
      onPlay: (songs, index) => _playSongsList(songs, index),
      onOpenPlaylist: _openPlaylist,
      onOpenPodcast: _openPodcastRadio,
      onOpenAlbum: (album) => showAlbumPreview(
        context,
        albumId: album.id,
        albumName: album.name,
        coverUrl: album.coverUrl,
        onPlay: (songs, index) => _playSongsList(songs, index),
      ),
    );
  }

  void _openAlbumPreview(rust.SongDto? song) {
    if (song == null) return;
    showAlbumPreview(
      context,
      albumId: song.albumId,
      albumName: song.album,
      coverUrl: song.coverUrl,
      onPlay: (songs, index) => _playSongsList(songs, index),
    );
  }

  /// 点列表: 用当前可见列表(搜索/歌单)重置队列, 从被点那首开始
  Future<void> _playFromList(rust.SongDto song) async {
    final songs = _visibleSongs;
    final start = songs.indexWhere((s) => s.id == song.id);
    _queue.setAll(songs, startAt: start < 0 ? 0 : start);
    _userStopped = false;
    _queuePlaylistId = null; // 搜索列表点播不算歌单队列
    await _playSong(song);
  }

  /// 搜索结果里点单曲: 用"可见单曲"重置队列(跳过无版权), 并定位到这首
  Future<void> _playFromSearch(rust.SongDto song) async {
    final songs = visibleSongs(_bundle?.songs ?? const <rust.SongDto>[], _liked);
    final start = songs.indexWhere((s) => s.id == song.id);
    if (songs.isEmpty) return;
    _queue.setAll(songs, startAt: start < 0 ? 0 : start);
    _userStopped = false;
    _queuePlaylistId = null;
    await _playSong(song);
  }

  /// 搜索结果: 歌手卡片 → 歌手页
  Future<void> _openSearchArtist(rust.SearchArtist artist) async {
    await showArtistDetail(
      context,
      artistId: artist.id,
      name: artist.name,
      onPlaySongs: (songs, i) => _playSongsList(songs, i),
      onOpenAlbum: (id, name, cover) => showAlbumPreview(
        context,
        albumId: id,
        albumName: name,
        coverUrl: cover,
        onPlay: (songs, i) => _playSongsList(songs, i),
      ),
    );
  }

  void _openSearchAlbum(rust.SearchAlbum album) {
    showAlbumPreview(
      context,
      albumId: album.id,
      albumName: album.name,
      coverUrl: album.coverUrl,
      onPlay: (songs, i) => _playSongsList(songs, i),
    );
  }

  /// 搜索结果: 歌单卡片 → 歌单详情
  void _openSearchPlaylist(rust.SearchPlaylistItem item) {
    _openPlaylist(
      rust.Playlist(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        trackCount: item.trackCount,
        special: false,
      ),
    );
  }

  /// 搜索结果: 播客卡片 → 播客详情
  void _openSearchPodcast(rust.SearchPodcast item) {
    _openPodcastRadio(
      rust.PodcastRadio(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        description: '',
        djName: item.djName,
        programCount: item.programCount,
        playCount: item.playCount,
      ),
    );
  }

  /// 跳过取不到直链的曲目(会员/版权限制), 最多绕队列一圈
  Future<void> _playSong(rust.SongDto song) async {
    _userStopped = false;
    var attempts = 0;
    var target = song;
    while (true) {
      if (await _resolveAndPlay(target)) return;
      attempts += 1;
      if (attempts >= _queue.items.length) {
        if (mounted) setState(() {});
        return;
      }
      final next = _queue.next();
      if (next == null) return;
      target = next;
    }
  }

  Future<bool> _resolveAndPlay(rust.SongDto song) async {
    // 没版权的曲目连取链都不用试; 自动续播时静默跳过(点列表才提示, 否则一路弹窗)
    if (!song.playable) return false;
    try {
      // 移动网络切网时会偶发 connection reset, 取链是幂等的, 值得重试
      final stream = await retryNetwork(
        () => rust.songUrl(
          trackId: song.id,
          level: AppSettings.instance.audioLevel,
        ),
      );
      final url = stream.url;
      if (url == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('《${song.name}》没有可用直链(会员曲目需先登录), 已跳过')),
          );
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
      final state = await _playback.play(
        trackId: song.id,
        url: url,
        title: song.name,
        artist: song.artist,
      );
      if (!mounted) return true;
      setState(() => _player = state);
      // 立刻按这首的响度给一次增益(未测到就先 0 dB, 轮询里会再补一次)
      _loudnessAppliedTrackId = playingId;
      unawaited(applyLoudnessForTrack(playingId, streamUrl: cacheKeyUrl));
      // 本地播放历史(未登录/离线时"最近听过"的来源); 失败不影响播放
      unawaited(rust.rememberPlay(song: song).catchError((_) => false));
      unawaited(_loadLyric(song.id));
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      return false;
    }
  }

  // ---------------- 歌词 ----------------

  Future<void> _loadLyric(BigInt trackId) async {
    if (_lyricTrackId == trackId) return;
    _lyricTrackId = trackId;
    if (mounted) {
      setState(() {
        _lyricLines = const [];
        _lyricTimes = const [];
        _lyricPlain = null;
        _lyricIndex = -1;
        _lyricError = null;
        _wordLines = const [];
      });
      _wordPositionMs.value = 0;
    }
    // 逐字歌词: 有则更好, 失败/缺失都静默回落到行级链。
    try {
      final word = await rust.wordLyricLines(trackId: trackId);
      if (!mounted || _lyricTrackId != trackId) return;
      if (word.hasWordTiming && word.lines.isNotEmpty) {
        setState(() {
          _lyricError = null;
          _lyricPlain = null;
          _wordLines = [
            for (var i = 0; i < word.lines.length; i++)
              WordLyricLineData(
                startMs: word.lines[i].startMs,
                endMs: word.lines[i].endMs,
                words: [
                  for (final w in word.lines[i].words)
                    WordLyricWord(
                      startMs: w.startMs,
                      endMs: w.endMs,
                      text: w.text,
                    ),
                ],
                sub: i < word.translationLines.length
                    ? word.translationLines[i]
                    : null,
              ),
          ];
        });
        _wordPositionMs.value = _player?.positionMs.toInt() ?? 0;
        return;
      }
    } catch (_) {
      // 歌词是“有则更好”: 逐字拉取失败不报错, 走原有行级链。
    }
    try {
      final lines = await rust.lyricLinesI18N(trackId: trackId);
      if (!mounted || _lyricTrackId != trackId) return;
      if (lines.isNotEmpty) {
        setState(() {
          _lyricLines = [
            for (final l in lines)
              ParsedLyricLine(timeMs: l.timeMs, text: l.text, sub: l.sub),
          ];
          _lyricTimes = [for (final l in lines) l.timeMs];
        });
        _syncLyricIndex(_player ?? PlayerView.empty);
        return;
      }
      // 逐行接口没有内容(纯文本/老格式歌词) → 退回原始 LRC
      await _loadRawLyric(trackId);
    } catch (e) {
      if (!mounted || _lyricTrackId != trackId) return;
      // 兜底: 原始 LRC 里往往还有纯文本可显示; 都没有才报错
      final ok = await _loadRawLyric(trackId);
      if (!ok && mounted && _lyricTrackId == trackId) {
        setState(() => _lyricError = friendlyError(e));
      }
    }
  }

  /// 原始 LRC 兜底(逐行接口失败/为空时): 有时间轴就等价于逐行高亮,
  /// 只有纯文本就走 [PlainLyricView]。返回是否有内容可用。
  Future<bool> _loadRawLyric(BigInt trackId) async {
    try {
      final raw = await rust.lyric(trackId: trackId);
      if (!mounted || _lyricTrackId != trackId) return false;
      final doc = parseLrc(raw);
      if (doc.isEmpty) return false;
      setState(() {
        _lyricError = null;
        if (doc.hasTimeline) {
          _lyricPlain = null;
          _lyricLines = doc.timed;
          _lyricTimes = [for (final l in doc.timed) l.timeMs];
        } else {
          _lyricLines = const [];
          _lyricTimes = const [];
          _lyricPlain = doc.plain;
        }
      });
      if (doc.hasTimeline) _syncLyricIndex(_player ?? PlayerView.empty);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _syncLyricIndex(PlayerView state) {
    if (!_showLyrics || _lyricTimes.isEmpty) return;
    final idx = lyricIndexAt(_lyricTimes, state.positionMs);
    if (idx == _lyricIndex) return;
    setState(() => _lyricIndex = idx);
    _scrollLyricTo(idx);
  }

  void _scrollLyricTo(int idx) {
    if (!_autoFollowLyric) return;
    if (!_lyricScroll.hasClients || idx < 0) return;
    final position = _lyricScroll.position;
    final target = idx * _lyricItemExtent - (position.viewportDimension - _lyricItemExtent) / 2;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    _lyricScroll.animateTo(
      clamped,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  void _toggleLyrics() {
    setState(() {
      _showLyrics = !_showLyrics;
      // 每次进入详情页都恢复"跟随 + 无选中", 避免上次留下的状态让人困惑
      _autoFollowLyric = true;
      _selectedLyricLines.clear();
    });
    if (_showLyrics) {
      // 仅展开期间提高刷新频率; 收起/切 tab 时必须停掉。
      _lyricTicker?.cancel();
      _lyricTicker = Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => _pollPlayer(),
      );
      if (_player != null) {
        _syncLyricIndex(_player!);
        _wordPositionMs.value = _player!.positionMs.toInt();
      }
    } else {
      _lyricTicker?.cancel();
      _lyricTicker = null;
    }
  }


  // ---------------- 详情页: 翻译 / 多选 / 分享 / 定位 ----------------

  /// 歌曲详情页(歌词页)是否可用: 就是歌词叠层本身, 从播放条点进来
  bool get _lyricSelecting => _selectedLyricLines.isNotEmpty;

  /// 歌词里有没有翻译(tlyric). 没有时整页不出现翻译开关, 免得点出个空开关
  bool get _hasLyricTranslation =>
      _wordLines.any((l) => (l.sub ?? '').trim().isNotEmpty) ||
      _lyricLines.any((l) => (l.sub ?? '').trim().isNotEmpty);

  /// 当前播放位置对应的歌词行(-1 = 还没唱到第一句)
  int get _currentLyricIndex {
    final pos = _player?.positionMs ?? BigInt.zero;
    if (_wordLines.isNotEmpty) return wordLineIndexAt(_wordLines, pos.toInt());
    if (_lyricTimes.isNotEmpty) return lyricIndexAt(_lyricTimes, pos);
    return -1;
  }

  /// 取第 [i] 行歌词的纯文本(逐字歌词把词拼回整行)
  String _lyricTextAt(int i) {
    if (_wordLines.isNotEmpty) {
      if (i < 0 || i >= _wordLines.length) return '';
      return [for (final w in _wordLines[i].words) w.text].join();
    }
    if (_lyricLines.isNotEmpty) {
      if (i < 0 || i >= _lyricLines.length) return '';
      return _lyricLines[i].text;
    }
    final plain = _lyricPlain;
    if (plain == null || i < 0 || i >= plain.length) return '';
    return plain[i];
  }

  /// 一键回到当前唱到的那句(并恢复跟随)
  void _locateCurrentLyric() {
    final idx = _currentLyricIndex;
    setState(() => _autoFollowLyric = true);
    if (idx < 0) {
      _toast('还没唱到第一句');
      return;
    }
    _scrollLyricTo(idx);
  }

  /// 用户手动滑歌词: 停止自动跟随(否则下一句会把列表拽回去, 根本看不远)
  void _pauseLyricFollow() {
    if (!_autoFollowLyric) return;
    setState(() => _autoFollowLyric = false);
  }

  /// 长按歌词行: 进入多选并选中该行; 之后点击任意行加/减选
  void _selectLyricLine(int index, {bool longPress = false}) {
    setState(() {
      if (longPress) {
        _selectedLyricLines.add(index);
      } else if (!_selectedLyricLines.remove(index)) {
        _selectedLyricLines.add(index);
      }
    });
    if (longPress && _selectedLyricLines.length == 1) {
      _toast('已选中 1 句歌词, 继续点击可多选');
    }
  }

  void _clearLyricSelection() {
    if (_selectedLyricLines.isEmpty) return;
    setState(() => _selectedLyricLines.clear());
  }

  /// 选中行的文本(按行号排序, 最多 8 行 —— 分享卡片放不下更多)
  List<String> _selectedLyricTexts() {
    final indexes = _selectedLyricLines.toList()..sort();
    return shareableLyricLines(
      [for (final i in indexes) _lyricTextAt(i)],
      max: 8,
    );
  }

  void _toggleLyricTranslation() {
    final next = !AppSettings.instance.lyricTranslation;
    setState(() {});
    unawaited(AppSettings.instance.update(lyricTranslation: next));
  }

  /// 分享(详情页右上角 / 选中歌词后的分享): 卡片带封面 + 歌词 + 二维码
  Future<void> _shareSong({List<String>? lyrics}) async {
    final song = _current;
    if (song == null) {
      _toast('当前没有正在播放的歌曲');
      return;
    }
    await showSongShareSheet(
      context,
      song: song,
      lyricLines: lyrics ?? const <String>[],
    );
  }

  Future<void> _shareSelectedLyrics() async {
    final lines = _selectedLyricTexts();
    if (lines.isEmpty) {
      _toast('没有可分享的歌词');
      return;
    }
    await _shareSong(lyrics: lines);
  }

  // ---------------- 登录 ----------------

  /// 黑胶会员(只读)页面; 未登录时页面内给「登录」入口。
  /// 入口:「我的」页的「黑胶会员」行 / 账号与会员页的「会员」分组(审查 P1-7.9)。
  Future<void> _openVip() => showVipPage(context, onLogin: _login);

  Future<void> _login() async {
    try {
      final cookie = await _auth.loginWeb();
      if (cookie == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('未获取到登录态')));
        return;
      }
      final ok = await _auth.commitCookie(cookie);
      if (ok) {
        // 记住这个账号(昵称/uid) 并设为当前账号, 下次可直接切换
        await _syncAccount();
      }
      await _refreshInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '登录成功, 账号已记住' : 'cookie 里没有 MUSIC_U, 登录未生效')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('登录失败: ${friendlyError(e)}')));
    }
  }

  /// 账号与会员页 —— 全 App 唯一账号面(账号簿/切换/添加/退出登录/黑胶会员).
  /// 审查 P1-7.10: 原先账号入口 3 处(AppBar / 我的页 / 设置页), 而「退出登录」
  /// 只在设置里; 现在入口只剩「我的」页资料头, 退出登录在账号页底部。
  Future<void> _openAccountPage() {
    return showAccountPage(
      context,
      info: _info,
      isAndroid: _auth.isAndroid,
      onLogin: _login,
      onLogout: () => _logout(),
      onOpenVip: _openVip,
      onSwitchAccount: _switchAccount,
      onRemoveAccount: (account) async {
        await rust.accountRemove(userId: account.userId);
        await _refreshInfo();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已从账号簿移除')),
        );
      },
    );
  }

  Future<void> _switchAccount(rust.AccountDto account) async {
    final name = account.nickname.isEmpty ? account.userId.toString() : account.nickname;
    try {
      final ok = await rust.accountSwitch(userId: account.userId);
      await _refreshInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ok ? '已切换到 $name' : '这个账号没存过凭据, 请重新登录')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('切换账号失败: ${friendlyError(e)}')));
    }
  }

  /// refresh init 信息(登录态/设备 id/会员状态)
  Future<void> _refreshInfo() async {
    try {
      final dir = await _playback.dataDir();
      final info = await rust.init(dataDir: dir);
      if (mounted) setState(() => _info = info);
      _actionsHost.value = _buildActionsHost();
      if (info.loggedIn) {
        await _loadLiked();
      } else {
        _liked = <BigInt>{};
      }
    } catch (_) {
      // init 失败保持旧状态
    }
  }

  /// 记账号资料(昵称/uid/会员)进账号簿; 离线拉不到只是没名字, 不影响登录态
  Future<void> _syncAccount() async {
    try {
      await rust.accountSyncActive();
    } catch (_) {}
  }

  /// 退出登录; thenLogin=true 表示切换账号(退出后立刻再开授权页)
  Future<void> _logout({bool thenLogin = false}) async {
    try {
      await _auth.logout();
      await _refreshInfo();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(thenLogin ? '已退出, 请登录另一个账号' : '已退出登录(账号仍留在账号簿)'),
        ),
      );
      if (thenLogin) await _login();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('退出登录失败: ${friendlyError(e)}')));
    }
  }

  // ---------------- 收藏(红心)与歌单 ----------------

  /// 拉一次"我喜欢的音乐"的 id 集合. 失败不影响播放, 只是红心状态未知。
  Future<void> _loadLiked() async {
    try {
      final ids = await retryNetwork(rust.likedIds);
      if (!mounted) return;
      setState(() => _liked = ids.toSet());
    } catch (_) {}
  }

  bool _isLiked(BigInt? trackId) => trackId != null && _liked.contains(trackId);

  /// "..." 菜单的回调宿主(登录态变化时重建)
  SongActionHost _buildActionsHost() => SongActionHost(
    loggedIn: _info?.loggedIn == true,
    isLiked: _isLiked,
    toggleLike: _toggleLikeFor,
    playNext: _playNextSong,
    addToPlaylist: _showAddToPlaylist,
    share: _showShareSong,
    comments: _showSongComments,
    openArtist: _openSongArtist,
    openAlbum: _openSongAlbum,
    download: _downloadSong,
    dislike: _dislikeSong,
    songWiki: (song) => showSongWiki(context, song: song),
    similarSongs: (song) => showSimilarSongs(
      context,
      song: song,
      onPlay: _playSongsList,
      onOpenPlaylist: _openPlaylist,
    ),
  );

  /// 任意曲目的红心切换(列表/播放条共用; 先乐观更新, 失败回滚)
  Future<void> _toggleLikeFor(rust.SongDto song) async {
    if (_info?.loggedIn != true) {
      _toast('收藏需要先登录');
      return;
    }
    final id = song.id;
    final wasLiked = _liked.contains(id);
    setState(() {
      if (wasLiked) {
        _liked.remove(id);
      } else {
        _liked.add(id);
      }
    });
    try {
      await rust.setLiked(trackId: id, liked: !wasLiked);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (wasLiked) {
          _liked.add(id);
        } else {
          _liked.remove(id);
        }
      });
      rethrow;
    }
  }

  Future<void> _playNextSong(rust.SongDto song) async {
    _queue.insertNext(song);
    if (mounted) {
      setState(() {});
      _toast('已添加到下一首播放');
    }
  }

  /// 收藏到歌单: 先选歌单, 再调接口. "我喜欢的音乐"走红心接口.
  Future<void> _showAddToPlaylist(rust.SongDto song) async {
    if (_info?.loggedIn != true) {
      _toast('收藏到歌单需要先登录');
      return;
    }
    final lists = await retryNetwork(rust.myPlaylists);
    if (!mounted) return;
    // 返回 PlaylistDto(选已有歌单) 或 'create'(新建歌单)
    final picked = await showModalBottomSheet<Object>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: Column(
            children: [
              ListTile(
                dense: true,
                title: const Text('收藏到歌单'),
                subtitle: Text(song.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: const Icon(Icons.add, size: 20),
                ),
                title: const Text('新建歌单'),
                subtitle: const Text('创建后把这首加进去'),
                onTap: () => Navigator.pop(sheetContext, 'create'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final pl = lists[i];
                    return ListTile(
                      dense: true,
                      leading: CoverArt(url: pl.coverUrl, size: 40, radius: 4),
                      title: Text(
                        pl.special ? '我喜欢的音乐' : pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${pl.trackCount} 首'),
                      onTap: () => Navigator.pop(sheetContext, pl),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    if (picked is String) {
      await _createPlaylistAndAdd(song);
      return;
    }
    final pl = picked as rust.Playlist;
    if (pl.special) {
      await rust.setLiked(trackId: song.id, liked: true);
      if (!mounted) return;
      setState(() => _liked.add(song.id));
      _toast('已加入我喜欢的音乐');
      return;
    }
    final ok = await rust.addToPlaylist(playlistId: pl.id, trackId: song.id);
    if (!mounted) return;
    _toast(ok ? '已收藏到《${pl.name}》' : '收藏未生效, 请稍后重试');
  }

  /// 新建歌单并把当前歌曲放进去
  Future<void> _createPlaylistAndAdd(rust.SongDto song) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await rust.createPlaylist(name: name);
      final ok = await rust.addToPlaylist(playlistId: id, trackId: song.id);
      if (!mounted) return;
      _toast(ok ? '已新建《$name》并收藏' : '歌单已建, 收藏未生效');
    } catch (e) {
      if (!mounted) return;
      _toast('新建歌单失败: ${friendlyError(e)}');
    }
  }

  Future<void> _showShareSong(rust.SongDto song) async {
    final link = 'https://music.163.com/#/song?id=${song.id}';
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享到动态'),
              onTap: () async {
                Navigator.pop(sheetContext);
                try {
                  final ok = await rust.shareResource(
                    kind: 'song',
                    resourceId: song.id,
                    msg: song.name,
                  );
                  if (mounted) _toast(ok ? '已分享到动态' : '分享未生效');
                } catch (e) {
                  if (mounted) _toast(friendlyError(e));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制链接'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await Clipboard.setData(ClipboardData(text: link));
                if (mounted) _toast('链接已复制');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSongComments(rust.SongDto song) async {
    await showCommentsSheet(
      context,
      kind: 'song',
      resourceId: song.id,
      title: '《${song.name}》的评论',
    );
  }

  Future<void> _openSongArtist(rust.SongDto song) async {
    if (song.artistId == BigInt.zero) {
      _toast('这首歌没有关联歌手信息');
      return;
    }
    await showArtistDetail(
      context,
      artistId: song.artistId,
      name: song.artist,
      onPlaySongs: (songs, i) => _playSongsList(songs, i),
      onOpenAlbum: (id, name, cover) => showAlbumPreview(
        context,
        albumId: id,
        albumName: name,
        coverUrl: cover,
        onPlay: (songs, i) => _playSongsList(songs, i),
      ),
    );
  }

  Future<void> _openSongAlbum(rust.SongDto song) async {
    await showAlbumPreview(
      context,
      albumId: song.albumId,
      albumName: song.album,
      coverUrl: song.coverUrl,
      onPlay: (songs, i) => _playSongsList(songs, i),
    );
  }

  Future<void> _downloadSong(rust.SongDto song) async {
    _toast('正在获取下载地址…');
    try {
      final stream = await retryNetwork(
        () => rust.songUrl(
          trackId: song.id,
          level: AppSettings.instance.audioLevel,
        ),
      );
      final raw = stream.url;
      if (raw == null || raw.isEmpty) {
        _toast('这首歌暂时没有可用直链(会员/版权限制)');
        return;
      }
      final url = preferHttpsStreamUrl(raw);
      final ext = url.contains('.flac') ? 'flac' : 'mp3';
      final name = '${song.artist} - ${song.name}.$ext';
      final saved = await PlatformBridge.download(url: url, filename: name);
      if (!mounted) return;
      _toast(saved == null ? '下载失败' : '已开始下载(Android 在通知栏/Download 目录)');
    } catch (e) {
      if (!mounted) return;
      _toast('下载失败: ${friendlyError(e)}');
    }
  }

  /// 无版权提示(与官方一致的"点了才告诉你")
  void _notifyUnplayable(rust.SongDto song) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('《${song.name}》暂无版权, 无法播放'),
          duration: const Duration(milliseconds: 1800),
        ),
      );
  }

  /// 红心/取消红心(当前曲目). 先乐观更新, 失败回滚。
  Future<void> _toggleLike() async {
    final song = _current;
    if (song == null) return;
    try {
      await _toggleLikeFor(song);
    } catch (e) {
      if (mounted) _toast('收藏失败: ${friendlyError(e)}');
    }
  }

  /// 当前队列是否来自私人FM(决定"不感兴趣"走 fm_trash 还是日推 dislike)
  bool _fmActive = false;

  /// 不感兴趣: FM 队列里走"不再播放", 其它场景走"少推这类歌"
  Future<void> _dislikeSong(rust.SongDto song) async {
    if (_info?.loggedIn != true) {
      _toast('不感兴趣需要先登录');
      return;
    }
    try {
      if (_fmActive) {
        await rust.trashFmSong(songId: song.id);
        if (!mounted) return;
        _toast('已从私人FM里去掉《${song.name}》');
      } else {
        await rust.dislikeRecommendSong(songId: song.id);
        if (!mounted) return;
        _toast('已减少《${song.name}》这类推荐');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('操作失败: ${friendlyError(e)}');
    }
  }

  /// 打开"关注/粉丝"列表(当前账号)
  Future<void> _openUserList({required bool startOnFans}) async {
    if (_info?.loggedIn != true) {
      _toast('登录后才能查看关注与粉丝');
      return;
    }
    await showUserList(context, startOnFans: startOnFans);
  }

  /// 打开歌单详情页(全屏路由): 曲目/收藏/分享/评论都在详情页里,
  /// 不再把曲目塞进搜索页列表。
  Future<void> _openPlaylist(rust.Playlist pl) async {
    await showPlaylistDetail(
      context,
      playlistId: pl.id,
      name: pl.name,
      coverUrl: pl.coverUrl,
      special: pl.special,
      loggedIn: _info?.loggedIn == true,
      likedIds: _liked,
      currentTrackId: _current?.id,
      currentPlaylistId: _queuePlaylistId,
      onPlaySongs: (songs, i) => _playSongsList(songs, i, playlistId: pl.id),
      onLikeChanged: (id, liked) => setState(() {
        if (liked) {
          _liked.add(id);
        } else {
          _liked.remove(id);
        }
      }),
    );
  }

  /// 从"我的"页打开"我喜欢的音乐"详情(要用 myPlaylists 找到这个歌单的 id)
  /// 解析"我喜欢的音乐"歌单 id(缓存). 失败静默: 只是"定位正在播放"少一个依据.
  Future<void> _resolveLikedPlaylistId() async {
    if (_likedPlaylistId != null) return;
    try {
      final pls = await rust.myPlaylists();
      for (final p in pls) {
        if (p.special) {
          if (mounted) setState(() => _likedPlaylistId = p.id);
          return;
        }
      }
    } catch (_) {
      // 未登录/网络异常: 下次进"我喜欢的音乐"详情时再试
    }
  }

  Future<void> _openLikedDetail() async {
    if (_info?.loggedIn != true) {
      _toast('登录后才能查看我喜欢的音乐');
      return;
    }
    setState(() => _busy = true);
    try {
      final pls = await retryNetwork(rust.myPlaylists);
      if (!mounted) return;
      rust.Playlist? found;
      for (final p in pls) {
        if (p.special) {
          found = p;
          break;
        }
      }
      final sp = found;
      if (sp == null) {
        _toast('没有找到"我喜欢的音乐"歌单');
        return;
      }
      _likedPlaylistId = sp.id;
      await showPlaylistDetail(
        context,
        playlistId: sp.id,
        name: '我喜欢的音乐',
        coverUrl: sp.coverUrl,
        special: true,
        loggedIn: _info?.loggedIn == true,
        likedIds: _liked,
        currentTrackId: _current?.id,
        currentPlaylistId: _queuePlaylistId,
        onPlaySongs: (songs, i) => _playSongsList(songs, i, playlistId: sp.id),
        onLikeChanged: (id, liked) => setState(() {
          if (liked) {
            _liked.add(id);
          } else {
            _liked.remove(id);
          }
        }),
      );
    } catch (e) {
      if (!mounted) return;
      _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 退出歌单浏览, 回到搜索
  void _closeLibrary() {
    setState(() {
      _library = const [];
      _libraryTitle = null;
      _libraryPlaylistId = null;
    });
  }

  // ---------------- 播放控制 ----------------

  Future<void> _toggle() async {
    final playing = _player?.playing ?? false;
    final state = playing ? await _playback.pause() : await _playback.resume();
    if (!mounted) return;
    setState(() => _player = state);
  }

  Future<void> _next() async {
    final next = _queue.next();
    if (next == null) return;
    await _playSong(next);
  }

  Future<void> _previous() async {
    final prev = _queue.previous();
    if (prev == null) return;
    await _playSong(prev);
  }

  /// 播放队列面板: 看队列 / 点项跳播 / 滑删或长按删(原来只有 "$inQueue/$total" 文本, 完全黑箱)
  Future<void> _openQueueSheet() async {
    if (_queue.items.isEmpty) {
      _toast('播放队列是空的');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: PlayQueueSheet(
          items: _queue.items,
          index: _queue.index,
          onSelect: (song) {
            Navigator.of(sheetContext).pop();
            _jumpToQueueSong(song);
          },
          onRemove: _removeFromQueue,
        ),
      ),
    );
  }

  /// 队列面板里点某一首: 定位到它再播(曲目可能已被别处挪过, 重新查下标)
  Future<void> _jumpToQueueSong(rust.SongDto song) async {
    final i = _queue.items.indexOf(song);
    if (i < 0) return;
    setState(() => _queue.jumpTo(i));
    await _playSong(song);
  }

  /// 队列面板删除: 删的不是当前项时只动列表; 删的是当前项时明确换到顶上来的下一首,
  /// 队列被删空则停播(否则播放器会继续放一首已经从队列里消失的歌)
  void _removeFromQueue(rust.SongDto song, bool wasCurrent) {
    final i = _queue.items.indexOf(song);
    if (i < 0) return;
    setState(() => _queue.removeAt(i));
    if (!wasCurrent) return;
    final next = _queue.current;
    if (next == null) {
      unawaited(_stopAfterQueueEmpty());
    } else {
      unawaited(_playSong(next));
    }
  }

  Future<void> _stopAfterQueueEmpty() async {
    _userStopped = true;
    _toast('播放队列已清空, 播放已停止');
    try {
      final state = await _playback.stop();
      if (mounted) setState(() => _player = state);
    } catch (_) {
      // 播放后端未就绪时忽略: 队列已经是空, UI 保持一致
    }
  }

  void _cycleMode() {
    setState(() {
      final modes = PlayMode.values;
      final i = (modes.indexOf(_queue.mode) + 1) % modes.length;
      _queue.mode = modes[i];
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(_modeLabels[_queue.mode]!),
          duration: const Duration(milliseconds: 900),
        ));
    });
  }

  Future<void> _seekTo(double ms) async {
    final target = ms.round();
    setState(() {
      _dragMs = null;
      _dragMax = null;
    });
    final state = await _playback.seek(BigInt.from(target));
    if (!mounted) return;
    setState(() => _player = state);
    _syncLyricIndex(state);
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final backAction = resolveHomeBackAction(
      showLyrics: _showLyrics,
      tab: _tab,
      libraryOpen: _libraryTitle != null,
    );
    return HomeBackGuard(
      action: backAction,
      onBack: () => _handleBack(backAction),
      child: _buildPage(context),
    );
  }

  /// 返回键: 先退一级(歌词 → 非首 tab → 歌单浏览态), 栈底才交还系统退出
  void _handleBack(HomeBackAction action) {
    switch (action) {
      case HomeBackAction.collapseLyrics:
        // 详情页里正在多选歌词时, 返回键先退多选(与常见相册/文件选择一致)
        if (_lyricSelecting) {
          _clearLyricSelection();
        } else {
          _toggleLyrics();
        }
      case HomeBackAction.resetTab:
        _onTabSelected(0);
      case HomeBackAction.closeLibrary:
        _closeLibrary();
      case HomeBackAction.exitApp:
        // canPop=true 时由系统退出; 走到这里说明确实无可退层级, 兜底交还系统
        SystemNavigator.pop();
    }
  }

  Widget _buildPage(BuildContext context) {
    final player = _player;
    final current = _current;
    final topBar = _buildTopBar(context, current);
    return Scaffold(
      appBar: topBar,
      // 没有 AppBar 时自己吃掉状态栏安全区(放在最外层, 搜索框/内容都不会顶到状态栏下)
      body: Padding(
        padding: EdgeInsets.only(
          top: topBar == null ? MediaQuery.paddingOf(context).top : 0,
        ),
        child: Column(
        children: [
          if (!_showLyrics && _tab == 0) _buildSearchBar(),
          // 有输入时给输入联想(原版交互); 历史/热词在搜索落地页里
          if (!_showLyrics && _tab == 0 && _exact != null)
            SearchExactBar(
              view: _exactView(_exact!),
              onPickArtist: _openExactArtist,
              onPickPlaylist: _openExactPlaylist,
              onPickRadio: _openExactRadio,
            ),
          if (!_showLyrics &&
              _tab == 0 &&
              _suggestions.isEmpty &&
              _exact == null &&
              _keywordSuggestions.isNotEmpty)
            KeywordSuggestBar(
              keywords: _keywordSuggestions,
              onSelected: _searchKeyword,
            ),
          if (!_showLyrics && _tab == 0 && _suggestions.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: SuggestionPanel(
                  items: _suggestions,
                  onSelected: (item) => _searchKeyword(item.title),
                ),
              ),
            ),
          if (!_showLyrics && _tab == 0 && _error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
                  if (_retryLast != null)
                    TextButton(
                      onPressed: () {
                        final retry = _retryLast;
                        setState(() => _error = null);
                        retry?.call();
                      },
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                // 歌词页盖在上面时 tab 树仍然存活(Offstage), 收起歌词不重建、不闪图
                Positioned.fill(
                  child: Offstage(offstage: _showLyrics, child: _buildTabPages()),
                ),
                if (_showLyrics) Positioned.fill(child: _buildLyrics()),
              ],
            ),
          ),
        ],
        ),
      ),
      // 播放条 + 底部导航: 没有曲目时播放条不占位置(Media3 连接后拿到的是一份空状态)
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (player != null && (player.trackId != null || current != null))
            _buildPlayerBar(context, player, current),
          NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: _onTabSelected,
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.search_outlined),
                selectedIcon: Icon(Icons.search),
                label: '搜索',
              ),
              NavigationDestination(
                icon: Icon(Icons.explore_outlined),
                selectedIcon: Icon(Icons.explore),
                label: '推荐',
              ),
              NavigationDestination(
                icon: Icon(Icons.dynamic_feed_outlined),
                selectedIcon: Icon(Icons.dynamic_feed),
                label: '关注',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: '我的',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: '设置',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _onTabSelected(int index) {
    if (_tab == index) return;
    _tabVisited.add(index);
    // 切 tab 一律收起歌词: 否则歌词页会一直占着焦点, 切过去看不到目标页面
    final wasLyrics = _showLyrics;
    setState(() {
      _tab = index;
      _searchFocus.unfocus();
      _showLyrics = false;
    });
    _lyricTicker?.cancel();
    _lyricTicker = null;
    // 回到搜索: 按设置决定是否丢弃上一次的输入/结果/错误
    if (index == 0) {
      if (AppSettings.instance.clearSearchOnTabSwitch &&
          (wasLyrics ||
              _controller.text.isNotEmpty ||
              _bundle != null ||
              _libraryTitle != null ||
              _error != null)) {
        _clearSearch();
      }
      _loadSearchHistory();
    }
  }

  /// 五个 tab 都塞进 IndexedStack(访问过的才真正构建), 保留各自的 State.

  /// 顶部栏: **只在它承载了导航里没有的信息时才出现**。
  ///
  /// - 歌词页: 曲名 + 收起按钮;
  /// - 歌单/正在播放/心动模式的浏览态: 当前列表名 + 返回按钮;
  /// - 其它情况(含「搜索」tab 首页、「推荐/关注/我的/设置」): **整条 AppBar 不出现**。
  ///   两处理由: ①这四页标题原本就是底部导航标签, 完全重复;
  ///   ②搜索页顶部的品牌横幅只是装饰, 用户明确要求去掉 —— 省下的 56dp 全给内容。
  ///   没有 AppBar 时也不再有顶部「登录」动作: 未登录引导在「我的」页(mine_view 的登录按钮)
  ///   与资料头点击(审查 P1-7.10 已定: 账号入口 3→1)。
  PreferredSizeWidget? _buildTopBar(BuildContext context, rust.SongDto? current) {
    final showBar = _showLyrics || _libraryTitle != null;
    if (!showBar) return null;
    return AppBar(
      // 大字号 + 动作图标会把默认 22sp 的标题挤成 "轻音 Mi…"(vivo 1440px 实测),
      // 标题固定用 titleMedium, 让品牌字至少完整显示
      titleTextStyle: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.w600),
      // 大字号设备会把标题挤成 "轻音 MiniN…", 用 FittedBox 缩排而不是截断
      title: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          _showLyrics
              ? (_lyricSelecting
                  ? '已选 ${_selectedLyricLines.length} 句'
                  : (current?.name ?? '歌词'))
              : (_libraryTitle ?? '轻音 MiniNCM'),
          maxLines: 1,
        ),
      ),
      leading: _showLyrics
          ? IconButton(
              icon: const Icon(Icons.expand_more),
              tooltip: '收起歌词',
              onPressed: _toggleLyrics,
            )
          : (_libraryTitle != null
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回搜索',
                  onPressed: _closeLibrary,
                )
              : null),
      actions: [
        // 歌曲详情页(歌词页)的右上角: 分享 / 翻译开关 / "..." 菜单
        if (_showLyrics) ...[
          if (_lyricSelecting) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享所选歌词',
              onPressed: _shareSelectedLyrics,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消选择',
              onPressed: _clearLyricSelection,
            ),
          ] else ...[
            if (_hasLyricTranslation)
              IconButton(
                icon: Icon(
                  Icons.translate,
                  color: AppSettings.instance.lyricTranslation
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                tooltip: AppSettings.instance.lyricTranslation
                    ? '关闭翻译'
                    : '显示翻译',
                onPressed: _toggleLyricTranslation,
              ),
            // "..." 从播放条挪到详情页里(播放条只留播放控制)
            if (current != null) SongOverflowButton(song: current, size: 22),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享这首歌',
              onPressed: () => _shareSong(),
            ),
          ],
        ] else if (_auth.isAndroid && _info?.loggedIn != true)
          // 登录(WebView)只在安卓端(桌面版还没有网页登录宿主)。
          // 审查 P1-7.10: 账号入口 3→1 —— 账号簿/切换/退出登录统一走「我的」页资料头。
          TextButton.icon(
            onPressed: _login,
            icon: const Icon(Icons.login, size: 18),
            label: const Text('登录'),
          ),
      ],
    );
  }

  Widget _buildTabPages() {
    return IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < 5; i++)
          if (_tabVisited.contains(i))
            _buildTabPage(i)
          else
            const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildTabPage(int index) {
    switch (index) {
      case 1:
        return RecommendView(
          key: ValueKey('recommend-${_info?.loggedIn}-${_info?.vip}'),
          loggedIn: _info?.loggedIn == true,
          onPlaySongs: _playSongsList,
          onOpenPlaylist: _openPlaylist,
          onOpenPodcast: _openPodcastRadio,
          onHeartMode: () => _heartMode(),
          onOpenDaily: _openDiscover,
          onPlayFm: (songs, index) {
            _fmActive = true;
            _playSongsList(songs, index);
          },
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
            onPlay: _playSongsList,
          ),
          onOpenNewRelease: () => showNewReleasePage(
            context,
            onPlaySongs: _playSongsList,
            onOpenAlbum: (album) => showAlbumPreview(
              context,
              albumId: album.id,
              albumName: album.name,
              coverUrl: album.coverUrl,
              onPlay: _playSongsList,
            ),
            onOpenArtist: (artist) => showArtistDetail(
              context,
              artistId: artist.id,
              name: artist.name,
              onPlaySongs: (songs, i) => _playSongsList(songs, i),
              onOpenAlbum: (id, name, cover) => showAlbumPreview(
                context,
                albumId: id,
                albumName: name,
                coverUrl: cover,
                onPlay: (songs, i) => _playSongsList(songs, i),
              ),
            ),
          ),
        );
      case 2:
        return FeedView(
          key: ValueKey('feed-${_info?.loggedIn}'),
          loggedIn: _info?.loggedIn == true,
          onLogin: _login,
          onPlaySongs: _playSongsList,
          onOpenUrl: PlatformBridge.openUrl,
        );
      case 3:
        return MineView(
          key: ValueKey('mine-${_info?.loggedIn}-${_info?.vip}'),
          loggedIn: _info?.loggedIn == true,
          onLogin: _login,
          onOpenAccounts: _openAccountPage,
          onPlaySongs: _playSongsList,
          onOpenPlaylist: _openPlaylist,
          onOpenPodcast: _openPodcastRadio,
          onOpenFollows: () => _openUserList(startOnFans: false),
          onOpenFolloweds: () => _openUserList(startOnFans: true),
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
            onPlay: _playSongsList,
            initiallySubscribed: true,
          ),
          onOpenRecent: _openRecent,
          onOpenLiked: _openLikedDetail,
          onOpenMessages: () => showMessagesPage(context),
          onOpenMedals: () => showMedalWall(context, isVip: _info?.vip == true),
          onOpenVip: _openVip,
          onPlayLiked: (songs, i) =>
              _playSongsList(songs, i, playlistId: _likedPlaylistId),
        );
      case 4:
        // 设置只剩下「App 怎么表现」的偏好开关 + 分组入口(审查 P1-7.9):
        // 账号/会员在「我的」, 诊断与数据是设置 → 关于里的二级页。
        return SettingsView(info: _info);
      default:
        return _buildSearchTab();
    }
  }

  Widget _buildSearchTab() {
    final query = _controller.text.trim();
    // 歌单浏览态优先(从我的/推荐点进来的)
    if (_libraryTitle != null) return _buildList();
    // 有上一轮结果就展示分区结果; 取消按钮会清空它
    if (_bundle != null) return _buildSearchResults();
    // 没输入关键词时: 搜索历史 + 猜你想搜 + 热门榜
    if (query.isEmpty) {
      return SearchLanding(
        history: _searchHistory,
        hot: _hotTerms,
        recommended: _recommendedKeyword,
        recommendedReason: _recommendedReason,
        onSelected: _searchKeyword,
        onClearHistory: _clearSearchHistory,
        hotLoading: _hotLoading,
        hotError: _hotError,
        onRetryHot: _loadSearchLanding,
      );
    }
    return _buildList();
  }

  /// 综合搜索结果: 单曲/歌手/专辑/歌单/播客分区
  Widget _buildSearchResults() {
    return SearchResultsView(
      bundle: _bundle!,
      liked: _liked,
      currentTrackId: _current?.id,
      onPlaySong: _playFromSearch,
      onOpenArtist: _openSearchArtist,
      onOpenAlbum: _openSearchAlbum,
      onOpenPlaylist: _openSearchPlaylist,
      onOpenPodcast: _openSearchPodcast,
      onMenu: (song) => showSongActionsSheet(context, song, _buildActionsHost()),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                labelText: '搜索',
                border: const OutlineInputBorder(),
                isDense: true,
                // 输入过东西或已有结果时给一个显式的清空按钮
                suffixIcon: (_controller.text.isEmpty && _bundle == null)
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _clearSearch,
                      ),
              ),
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(width: 8),
          // 不再并排放「取消」: 它与输入框里的清空 suffix 是同一个动作
          // (_clearSearch), 两个同义按钮只会让人不知道该按哪个(审查 P1-7.4)
          FilledButton(
            onPressed: _busy ? null : _search,
            child: Text(_busy ? '搜索中' : '搜索'),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final current = _current;
    if (_libraryTitle == null) {
      return const Center(child: Text('输入关键词后搜索'));
    }
    final songs = _visibleSongs;
    final hidden = _hiddenUnplayable;
    if (songs.isEmpty) {
      return Center(
        child: Text(hidden > 0 ? '这里没有可播放的曲目($hidden 首无版权已隐藏)' : '这个歌单是空的'),
      );
    }
    // 列表顶部一句说明: 无版权且没收藏的曲目按官方行为直接不出现, 但要让用户知道少了什么
    final headerCount = hidden > 0 ? 1 : 0;
    return ListView.builder(
      itemCount: songs.length + headerCount,
      itemBuilder: (context, i) {
        if (headerCount == 1 && i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '已隐藏 $hidden 首无版权曲目',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final s = songs[i - headerCount];
        final active = current?.id == s.id;
        // 没版权: 整行灰掉 + "无版权"标, 点了才提示(官方同款行为)
        return SongTile(
          song: s,
          active: active,
          liked: _isLiked(s.id),
          onTap: () {
            if (s.playable) {
              _playFromList(s);
            } else {
              _notifyUnplayable(s);
            }
          },
          onMenu: () => showSongActionsSheet(context, s, _buildActionsHost()),
        );
      },
    );
  }

  /// 歌曲详情页正文 = 歌词 + (定位当前句 / 底部次要控制)
  Widget _buildLyrics() {
    // 多选态: 点行 = 加/减选; 非多选态点击不做事(避免误改焦点)
    final onTap = _lyricSelecting ? (int i) => _selectLyricLine(i) : null;
    final onLong = _selectLyricLine;
    final showTranslation = AppSettings.instance.lyricTranslation;

    final Widget body;
    if (_wordLines.isNotEmpty) {
      body = WordLyricView(
        lines: _wordLines,
        positionMs: _wordPositionMs,
        controller: _lyricScroll,
        itemExtent: _lyricItemExtent,
        showTranslation: showTranslation,
        selected: _selectedLyricLines,
        onLineTap: onTap,
        onLineLongPress: onLong,
        autoScroll: _autoFollowLyric,
      );
    } else if (_lyricPlain != null) {
      body = PlainLyricView(
        lines: _lyricPlain!,
        controller: _lyricScroll,
        selected: _selectedLyricLines,
        onLineTap: onTap,
        onLineLongPress: onLong,
      );
    } else if (_lyricError != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(_lyricError!, textAlign: TextAlign.center)),
      );
    } else if (_lyricLines.isEmpty) {
      body = const Center(child: Text('暂无歌词'));
    } else {
      body = TimedLyricView(
        lines: _lyricLines,
        activeIndex: _lyricIndex,
        controller: _lyricScroll,
        itemExtent: _lyricItemExtent,
        showTranslation: showTranslation,
        selected: _selectedLyricLines,
        onLineTap: onTap,
        onLineLongPress: onLong,
      );
    }

    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            // 只认"手指拖动"(dragDetails != null): 自动跟随用的 animateTo 不会误判
            onNotification: (n) {
              if (n is ScrollUpdateNotification && n.dragDetails != null) {
                _pauseLyricFollow();
              }
              return false;
            },
            child: Stack(
              children: [
                Positioned.fill(child: body),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: IconButton.filledTonal(
                    tooltip: '定位到当前歌词',
                    icon: const Icon(Icons.my_location, size: 20),
                    onPressed: _locateCurrentLyric,
                  ),
                ),
              ],
            ),
          ),
        ),
        _buildDetailActionStrip(context),
      ],
    );
  }

  /// 详情页底部的次要控制: 播放模式 / 心动模式 / 播放队列.
  ///
  /// 播放条合并成一行后只留"喜欢 + 上一首/播放/下一首", 这三个低频动作挪到这里,
  /// 保证详情页里也够得着(不用先收起详情页).
  Widget _buildDetailActionStrip(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.4)),
        ),
      ),
      // 300dp 窄屏 + 大字号会把三个带文字的按钮挤爆, 横向可滚更稳
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            TextButton.icon(
              onPressed: _cycleMode,
              icon: Icon(_modeIcons[_queue.mode], size: 20),
              label: Text(_modeLabels[_queue.mode]!),
            ),
            TextButton.icon(
              onPressed: _busy ? null : _heartMode,
              icon: const Icon(Icons.auto_awesome, size: 20),
              label: const Text('心动'),
            ),
            TextButton.icon(
              onPressed: _openQueueSheet,
              icon: const Icon(Icons.queue_music, size: 20),
              label: Text('队列 ${_queue.items.length}'),
            ),
          ],
        ),
      ),
    );
  }

  /// 播放条上的紧凑图标按钮: 40dp 点击区 + 无内边距.
  ///
  /// 合并成一行后总宽 = 封面 52 + 4×40 = 212dp, 300dp 窄屏上文本仍有 ~90dp,
  /// 配合 Expanded + ellipsis 不会溢出.
  Widget _barIcon({
    required String tooltip,
    required Widget icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      tooltip: tooltip,
      icon: icon,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
    );
  }

  Widget _buildPlayerBar(BuildContext context, PlayerView player, rust.SongDto? current) {
    final dur = player.durationMs.toDouble();
    // 拖动中冻结量程: 自动续播会让 duration 突跳
    final maxMs = _dragMax ?? (dur <= 0 ? 1.0 : dur);
    final pos = (_dragMs ?? player.positionMs.toDouble()).clamp(0.0, maxMs);
    final inQueue = _queue.isEmpty ? 1 : _queue.index + 1;
    return Material(
      elevation: 8,
      // 播放条贴在 NavigationBar 之上, 底部的系统安全区由 NavigationBar 自己的 SafeArea
      // 负责; 这里若再吃一次 bottom inset, 就会在播放条与底栏之间留出一条空白(R4).
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: pos,
                max: maxMs,
                onChangeStart: dur <= 0 ? null : (v) => setState(() { _dragMax = dur; _dragMs = v; }),
                onChanged: dur <= 0 ? null : (v) => setState(() => _dragMs = v),
                onChangeEnd: dur <= 0 ? null : (v) => _seekTo(v),
              ),
              // 歌曲信息与播放控制同排(用户明确要求合并); 文本块 Expanded + ellipsis,
              // 窄屏/大字号下只会变短不会溢出.
              Row(
                children: [
                  // 封面: 点开看专辑大图 + 曲目
                  GestureDetector(
                    onTap: () => _openAlbumPreview(current),
                    child: Padding(
                      padding: const EdgeInsets.only(left: 8, right: 4),
                      child: CoverArt(url: current?.coverUrl, size: 40, radius: 6),
                    ),
                  ),
                  Expanded(
                    child: InkWell(
                      onTap: _toggleLyrics,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    current?.name ?? '未在播放',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleSmall,
                                  ),
                                ),
                                if (current?.vip == true) const VipBadge(small: true),
                                if (current?.paid == true && current?.vip != true)
                                  const PaidBadge(),
                              ],
                            ),
                            Text(
                              '${_fmt(player.positionMs)} / ${_fmt(player.durationMs)}'
                              '  ${current?.artist ?? ''}'
                              '  $inQueue/${_queue.items.length}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // 红心 + 上一首/播放/下一首: 与歌曲信息挤在同一行(用户要求把两排合并),
                  // 紧凑点击区 40dp; 播放模式/心动/队列挪到详情页底部, 低频动作不占播放条.
                  _barIcon(
                    tooltip: _isLiked(current?.id) ? '取消喜欢' : '喜欢',
                    icon: Icon(
                      _isLiked(current?.id) ? Icons.favorite : Icons.favorite_border,
                      size: 22,
                      color: _isLiked(current?.id)
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onPressed: _toggleLike,
                  ),
                  _barIcon(
                    tooltip: '上一首',
                    icon: const Icon(Icons.skip_previous, size: 26),
                    onPressed: _previous,
                  ),
                  _barIcon(
                    tooltip: player.playing ? '暂停' : '播放',
                    icon: Icon(
                      player.playing ? Icons.pause_circle : Icons.play_circle,
                      size: 38,
                    ),
                    onPressed: _toggle,
                  ),
                  _barIcon(
                    tooltip: '下一首',
                    icon: const Icon(Icons.skip_next, size: 26),
                    onPressed: _next,
                  ),
                ],
              ),
              // 手势导航条会吞掉最底部约 20dp 的点击, 留一点安全边距
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
