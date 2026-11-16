import 'rust/api.dart' as rust;
import 'song_actions.dart' show SongActionSource;

/// 起播一批曲目: 用 [songs] 重置播放队列并从 [index] 开始播。
///
/// [playlistId] 是队列来源歌单(歌单详情页「定位正在播放」用), 不传即非歌单队列;
/// [source] 是队列来源标记(每日推荐 / 私人FM 等, 歌曲菜单据此决定「不感兴趣」走哪条接口)。
typedef PlaySongsHandler = Future<void> Function(
  List<rust.SongDto> songs,
  int index, {
  BigInt? playlistId,
  SongActionSource source,
});

/// 歌单内搜索「只添加当前歌」: 保留现有队列把 [song] 追加到末尾。
typedef AppendNextSongHandler = Future<void> Function(rust.SongDto song);

/// 打开歌单详情页(全屏路由)。
typedef OpenPlaylistHandler = Future<void> Function(rust.Playlist playlist);

/// 播放能力的单入口(顶层单例, 与通道 A 的 `playerBar*` 同一写法)。
///
/// 背景: 播放能力原来有三条通道并存 —— `nowPlayingSongId`(谁在播)、
/// `UserNav/ArtistNav.onPlaySongs`(静态字段注入)、`onPlaySongs` 构造参数(逐层
/// 透传到每个 section 和行)。同一个回调在 20 个文件里各写一遍, 新增页面必须同时
/// 记住三条, 历史上的「某处点了没反应」多半源于漏接其中之一。
///
/// 现在只剩一条: 真实实现在 `_HomePageState.initState` 里 [bind] 一次
/// (main.dart 的 `_playSongsList` / `_appendSongToQueue` / `_openPlaylist`);
/// 任何页面、任何深度的区块直接 `PlaybackBridge.instance.playSongs(...)`。
///
/// 测试需要假实现时用 [debugOverride] 注入、[resetDebugOverride] 复位,
/// 不再需要把回调塞进每个构造函数。未绑定(单独 pump 一个二级页)时
/// [canPlaySongs] 为 false, 页面据此给「当前页面不支持播放」的提示。
class PlaybackBridge {
  PlaybackBridge._();

  /// 全局唯一实例。刻意不用依赖注入框架(见 .pi/plans/arch-audit-frontend-2026-11-15.md §3.5)。
  static final PlaybackBridge instance = PlaybackBridge._();

  PlaySongsHandler? _playSongs;
  AppendNextSongHandler? _appendNext;
  OpenPlaylistHandler? _openPlaylist;

  PlaySongsHandler? _debugPlaySongs;
  AppendNextSongHandler? _debugAppendNext;
  OpenPlaylistHandler? _debugOpenPlaylist;

  /// 有没有可用的起播实现(二级页据此决定是否提示「当前页面不支持播放」)
  bool get canPlaySongs => (_debugPlaySongs ?? _playSongs) != null;
  bool get canAppendNext => (_debugAppendNext ?? _appendNext) != null;
  bool get canOpenPlaylist => (_debugOpenPlaylist ?? _openPlaylist) != null;

  /// 生产装配: 外壳启动时注入真实实现, 整个进程只调这一次(重复调用幂等)。
  void bind({
    required PlaySongsHandler playSongs,
    AppendNextSongHandler? appendNext,
    OpenPlaylistHandler? openPlaylist,
  }) {
    _playSongs = playSongs;
    _appendNext = appendNext ?? _appendNext;
    _openPlaylist = openPlaylist ?? _openPlaylist;
  }

  /// 外壳销毁时断开(避免测试之间串味: 上一个 HomePage 的实现被下一个用例用到)。
  void unbind() {
    _playSongs = null;
    _appendNext = null;
    _openPlaylist = null;
  }

  /// 测试注入: 优先级高于 [bind]; 传 null 的项保持原状。用完记得 [resetDebugOverride]。
  void debugOverride({
    PlaySongsHandler? playSongs,
    AppendNextSongHandler? appendNext,
    OpenPlaylistHandler? openPlaylist,
  }) {
    if (playSongs != null) _debugPlaySongs = playSongs;
    if (appendNext != null) _debugAppendNext = appendNext;
    if (openPlaylist != null) _debugOpenPlaylist = openPlaylist;
  }

  /// 清掉 [debugOverride] 注入的假实现。
  void resetDebugOverride() {
    _debugPlaySongs = null;
    _debugAppendNext = null;
    _debugOpenPlaylist = null;
  }

  /// 重置队列并从 [index] 开始播放。未绑定实现时静默返回(页面对不能用 [canPlaySongs] 拦)。
  Future<void> playSongs(
    List<rust.SongDto> songs,
    int index, {
    BigInt? playlistId,
    SongActionSource source = SongActionSource.other,
  }) async {
    if (songs.isEmpty) return;
    final handler = _debugPlaySongs ?? _playSongs;
    if (handler == null) return;
    await handler(songs, index, playlistId: playlistId, source: source);
  }

  /// 把 [song] 追加到当前队列末尾。没有可用实现时退化为「用这一首起播」
  /// (与 main 的 `_appendSongToQueue` 在空队列时的行为一致)。
  Future<void> appendNext(rust.SongDto song) async {
    final handler = _debugAppendNext ?? _appendNext;
    if (handler == null) return playSongs([song], 0);
    await handler(song);
  }

  /// 打开歌单详情页。未绑定时什么都不做(页面上的歌单卡片保持不可点)。
  Future<void> openPlaylist(rust.Playlist playlist) async {
    final handler = _debugOpenPlaylist ?? _openPlaylist;
    if (handler == null) return;
    await handler(playlist);
  }
}
