import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/album_preview.dart';
import 'src/similar_sheet.dart';
import 'src/user_list_page.dart';
import 'src/app_settings.dart';
import 'src/artist_page.dart';
import 'src/auth.dart';
import 'src/cover_art.dart';
import 'src/detail_page.dart';
import 'src/discover.dart';
import 'src/feed_view.dart';
import 'src/lyric.dart';
import 'src/library_view.dart';
import 'src/messages_page.dart';
import 'src/new_release_page.dart';
import 'src/mine_view.dart';
import 'src/net_retry.dart';
import 'src/playback.dart';
import 'src/queue.dart';
import 'src/platform.dart';
import 'src/recommend_view.dart';
import 'src/search_landing.dart';
import 'src/search_results.dart';
import 'src/search_suggest.dart';
import 'src/settings_view.dart';
import 'src/song_actions.dart';
import 'src/song_tile.dart';
import 'src/song_wiki.dart';
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
          theme: ThemeData(
            colorSchemeSeed: const Color(0xFFE60026),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFFE60026),
            brightness: Brightness.dark,
            useMaterial3: true,
          ),
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
  List<rust.LyricLineDto> _lyricLines = const [];
  List<BigInt> _lyricTimes = const [];
  BigInt? _lyricTrackId;
  String? _lyricError;
  int _lyricIndex = -1;
  bool _showLyrics = false;

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
  List<rust.SuggestItemDto> _suggestions = const [];
  List<String> _searchHistory = const [];

  // ---- 搜索落地页(热词/推荐词) ----
  List<rust.HotSearchTermDto> _hotTerms = const [];
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
    // "..." 菜单的动作宿主在 Navigator 之上, 先放一份(登录态变化时再刷新)
    _actionsHost.value = _buildActionsHost();
    _searchFocus.addListener(_onSearchFocusChanged);
    _bootstrap();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) => _pollPlayer());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _suggestDebounce?.cancel();
    _searchFocus.removeListener(_onSearchFocusChanged);
    _searchFocus.dispose();
    _lyricScroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final dir = await _playback.dataDir();
      final info = await rust.init(dataDir: dir);
      await AppSettings.instance.load(info.dataDir);
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
      setState(() => _error = '$e');
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
    setState(() => _player = state);
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
      setState(() => _suggestions = const []);
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
      final hot = await retryNetwork(rust.hotSearch);
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
      setState(() => _suggestions = const []);
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final items = await rust.searchSuggest(keywords: q);
        if (!mounted || _controller.text.trim() != q) return;
        setState(() => _suggestions = items);
      } catch (_) {
        // 建议是锦上添花, 失败静默
      }
    });
  }

  Future<void> _searchKeyword(String keyword) async {
    _controller.text = keyword;
    _controller.selection = TextSelection.collapsed(offset: keyword.length);
    setState(() => _suggestions = const []);
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
    showDiscoverSheet(
      context,
      onPlaySongs: (songs, index) => _playSongsList(songs, index),
      onOpenPlaylist: (pl) => _openPlaylist(pl),
      onDislike: (song) => rust.dislikeRecommendSong(songId: song.id),
    );
  }

  /// 直接打开某个播客的详情页(推荐/我的页面的卡片点进来)
  void _openPodcastRadio(rust.PodcastRadioDto radio) {
    showPodcastDetail(
      context,
      radio: radio,
      onPlaySongs: (songs, index) => _playSongsList(songs, index),
    );
  }

  void _openRecent() {
    showRecentSheet(
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
  Future<void> _openSearchArtist(rust.SearchArtistDto artist) async {
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

  void _openSearchAlbum(rust.SearchAlbumDto album) {
    showAlbumPreview(
      context,
      albumId: album.id,
      albumName: album.name,
      coverUrl: album.coverUrl,
      onPlay: (songs, i) => _playSongsList(songs, i),
    );
  }

  /// 搜索结果: 歌单卡片 → 歌单详情
  void _openSearchPlaylist(rust.SearchPlaylistDto item) {
    _openPlaylist(
      rust.PlaylistDto(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        trackCount: item.trackCount,
        special: false,
      ),
    );
  }

  /// 搜索结果: 播客卡片 → 播客详情
  void _openSearchPodcast(rust.SearchPodcastDto item) {
    _openPodcastRadio(
      rust.PodcastRadioDto(
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
      final state = await _playback.play(
        trackId: song.id,
        url: url,
        title: song.name,
        artist: song.artist,
      );
      if (!mounted) return true;
      setState(() => _player = state);
      // 本地播放历史(未登录/离线时"最近听过"的来源); 失败不影响播放
      unawaited(rust.rememberPlay(song: song).catchError((_) => false));
      unawaited(_loadLyric(song.id));
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
        _lyricIndex = -1;
        _lyricError = null;
      });
    }
    try {
      final lines = await rust.lyricLinesI18N(trackId: trackId);
      if (!mounted || _lyricTrackId != trackId) return;
      setState(() {
        _lyricLines = lines;
        _lyricTimes = [for (final l in lines) l.timeMs];
      });
      _syncLyricIndex(_player ?? PlayerView.empty);
    } catch (e) {
      if (!mounted || _lyricTrackId != trackId) return;
      setState(() => _lyricError = '$e');
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
    setState(() => _showLyrics = !_showLyrics);
    if (_showLyrics && _player != null) {
      _syncLyricIndex(_player!);
    }
  }

  // ---------------- 登录 ----------------

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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  /// 账号面板: 账号簿(记住的账号可一键切换) + 添加账号 + 退出登录
  /// 弹出式菜单在 AppBar 里不好点, 用底部面板; 切换账号不需要重新扫码,
  /// 因为账号簿只存"登录凭据", 设备指纹始终是同一套。
  Future<void> _showAccountSheet() async {
    var saved = const <rust.AccountDto>[];
    try {
      saved = await rust.accounts();
    } catch (_) {
      // 账号簿读不出来不影响登录态, 面板里只显示"添加账号"
    }
    if (!mounted) return;
    final loggedIn = _info?.loggedIn == true;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              title: const Text('账号'),
              subtitle: Text(loggedIn ? '退出只清登录凭据, 设备指纹保持不变' : '未登录'),
            ),
            const Divider(height: 1),
            if (saved.isEmpty)
              const ListTile(
                dense: true,
                title: Text('还没有记住的账号'),
                subtitle: Text('登录一次后会自动记住, 之后可直接切换'),
              ),
            for (final account in saved)
              ListTile(
                leading: Icon(account.active ? Icons.check_circle : Icons.person_outline),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(
                        account.nickname.isEmpty ? '账号 ${account.userId}' : account.nickname,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (account.vip) const VipBadge(small: true),
                  ],
                ),
                subtitle: Text(account.active ? '当前账号' : '点击切换'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '忘记这个账号',
                  onPressed: () async {
                    Navigator.pop(sheetContext);
                    await rust.accountRemove(userId: account.userId);
                    await _refreshInfo();
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('已从账号簿移除')),
                    );
                  },
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _switchAccount(account);
                },
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('添加账号'),
              subtitle: const Text('打开官方登录页'),
              onTap: () {
                Navigator.pop(sheetContext);
                _login();
              },
            ),
            if (loggedIn)
              ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('退出登录'),
                subtitle: const Text('账号仍留在账号簿, 下次一键切回'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _logout();
                },
              ),
          ],
        ),
      ),
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
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
    final pl = picked as rust.PlaylistDto;
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
      if (mounted) _toast('收藏失败: $e');
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
  Future<void> _openPlaylist(rust.PlaylistDto pl) async {
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
      rust.PlaylistDto? found;
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
    final player = _player;
    final current = _current;
    return Scaffold(
      appBar: AppBar(
        // 大字号 + 三个动作图标会把默认 22sp 的标题挤成 "轻音 Mi…"(vivo 1440px 实测),
        // 标题固定用 titleMedium, 让品牌字至少完整显示
        titleTextStyle: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
        // 大字号设备(vivo 1440px + font_scale>1)会把标题挤成 "轻音 MiniN…",
        // 用 FittedBox 缩排而不是截断
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            _showLyrics
                ? (current?.name ?? '歌词')
                : (_tab == 0
                    ? (_libraryTitle ?? '轻音 MiniNCM')
                    : switch (_tab) {
                        1 => '推荐',
                        2 => '关注',
                        3 => '我的',
                        _ => '设置',
                      }),
            maxLines: 1,
          ),
        ),
        leading: _showLyrics
            ? IconButton(
                icon: const Icon(Icons.expand_more),
                tooltip: '收起歌词',
                onPressed: _toggleLyrics,
              )
            : (_tab == 0 && _libraryTitle != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回搜索',
                    onPressed: _closeLibrary,
                  )
                : null),
        actions: [
          // 登录(WebView)/账号簿/退出登录只在安卓端(桌面版还没有网页登录宿主)
          if (_auth.isAndroid) ...[
            if (_info?.loggedIn == true)
              const SizedBox.shrink()
            else
              TextButton.icon(
                onPressed: _login,
                icon: const Icon(Icons.login, size: 18),
                label: const Text('登录'),
              ),
            // 账号簿入口常驻: 退出后账号仍在簿里, 需要能一键切回
            IconButton(
              tooltip: '账号',
              icon: const Icon(Icons.account_circle),
              onPressed: _showAccountSheet,
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (!_showLyrics && _tab == 0) _buildSearchBar(),
          // 有输入时给输入联想(原版交互); 历史/热词在搜索落地页里
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
          onOpenAccounts: _showAccountSheet,
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
          onPlayLiked: (songs, i) =>
              _playSongsList(songs, i, playlistId: _likedPlaylistId),
        );
      case 4:
        return SettingsView(
          info: _info,
          isAndroid: _auth.isAndroid,
          onLogin: _login,
          onLogout: () => _logout(),
          onShowAccounts: _showAccountSheet,
          onClearSearchHistory: _clearSearchHistory,
        );
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
          FilledButton(
            onPressed: _busy ? null : _search,
            child: Text(_busy ? '搜索中' : '搜索'),
          ),
          // 显式取消: 清掉上一轮结果并回到搜索落地页
          if (_controller.text.isNotEmpty || _bundle != null || _error != null) ...[
            const SizedBox(width: 2),
            TextButton(
              onPressed: _busy ? null : _clearSearch,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('取消'),
            ),
          ],
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

  Widget _buildLyrics() {
    if (_lyricError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text('歌词获取失败: $_lyricError', textAlign: TextAlign.center)),
      );
    }
    if (_lyricLines.isEmpty) {
      return const Center(child: Text('暂无歌词'));
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: _lyricScroll,
      itemExtent: _lyricItemExtent,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
      itemCount: _lyricLines.length,
      itemBuilder: (context, i) {
        final line = _lyricLines[i];
        final active = i == _lyricIndex;
        final text = line.text.isEmpty ? '♪' : line.text;
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: active ? 18 : 15,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? scheme.primary : scheme.onSurfaceVariant,
                ),
              ),
              if (line.sub != null)
                Text(
                  line.sub!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? scheme.primary.withValues(alpha: 0.8) : scheme.outline,
                  ),
                ),
            ],
          ),
        );
      },
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
      child: SafeArea(
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
              // 窄屏(411dp) + 大字号下, 标题若和 5 个按钮抢同一行会被挤成"晴…",
              // 因此标题独占一行, 控件单独居中一行.
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
                  // 红心: 当前曲目是否在我喜欢的音乐里, 点一下即收藏/取消
                  IconButton(
                    tooltip: _isLiked(current?.id) ? '取消喜欢' : '喜欢',
                    icon: Icon(
                      _isLiked(current?.id) ? Icons.favorite : Icons.favorite_border,
                      color: _isLiked(current?.id)
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                    onPressed: _toggleLike,
                  ),
                  // 正在播放的曲目也有完整操作菜单
                  if (current != null)
                    SongOverflowButton(song: current, size: 22),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: _modeLabels[_queue.mode],
                    icon: Icon(_modeIcons[_queue.mode]),
                    onPressed: _cycleMode,
                  ),
                  IconButton(icon: const Icon(Icons.skip_previous), onPressed: _previous),
                  IconButton(
                    iconSize: 36,
                    icon: Icon(player.playing ? Icons.pause_circle : Icons.play_circle),
                    onPressed: _toggle,
                  ),
                  IconButton(icon: const Icon(Icons.skip_next), onPressed: _next),
                  // 心动模式: 以当前曲目为种子续播一队智能推荐(原"中止"位置)
                  IconButton(
                    tooltip: '心动模式',
                    icon: const Icon(Icons.auto_awesome),
                    onPressed: _busy ? null : _heartMode,
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
