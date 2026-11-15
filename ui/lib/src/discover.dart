import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'adaptive_text.dart';
import 'daily_cache.dart';
import 'net_retry.dart';
import 'now_playing.dart';
import 'rust/api.dart' as rust;
import 'error_views.dart' show FullError;
import 'song_actions.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'state_views.dart';

typedef SongListLoader = Future<List<rust.SongDto>> Function();
typedef PlaylistListLoader = Future<List<rust.Playlist>> Function();
typedef DateListLoader = Future<List<String>> Function();
typedef HistorySongsLoader = Future<List<rust.SongDto>> Function(String date);

/// 每日推荐: 推荐歌曲 / 推荐歌单 / 历史日推 三个页签.
/// loadSongs/loadPlaylists/loadHistoryDates 可注入(测试用), 默认走 Rust 接口.
///
/// 审查 §5.6: 3 个列表 + 内部二级层级塞进 72% 高的 sheet 局促, 改为全页
/// [Scaffold](与歌单详情/新歌新碟一致); 行为与注入点不变。
Future<void> showDiscoverPage(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  required void Function(rust.Playlist playlist) onOpenPlaylist,
  SongListLoader? loadSongs,
  PlaylistListLoader? loadPlaylists,
  DateListLoader? loadHistoryDates,
  HistorySongsLoader? loadHistorySongs,
  LocalDaysLoader? loadLocalDays,
}) {
  final songs = loadSongs ?? rust.dailyRecommendSongs;
  final playlists = loadPlaylists ?? rust.dailyRecommendPlaylists;
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => DailyRecommendPage(
        loadSongs: songs,
        loadPlaylists: playlists,
        loadHistoryDates: loadHistoryDates ?? rust.historyRecommendDates,
        loadHistorySongs:
            loadHistorySongs ??
            (date) => rust.historyRecommendSongs(date: date),
        loadLocalDays: loadLocalDays,
        onPlaySongs: onPlaySongs,
        onOpenPlaylist: onOpenPlaylist,
      ),
    ),
  );
}

/// 每日推荐全页(原 showDiscoverSheet 的弹层内容)。
class DailyRecommendPage extends StatelessWidget {
  const DailyRecommendPage({
    super.key,
    required this.loadSongs,
    required this.loadPlaylists,
    required this.loadHistoryDates,
    required this.loadHistorySongs,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
    this.loadLocalDays,
  });

  final SongListLoader loadSongs;
  final PlaylistListLoader loadPlaylists;
  final DateListLoader loadHistoryDates;
  final HistorySongsLoader loadHistorySongs;

  /// 本地缓存的每日推荐歌单(设置里关掉缓存时为 null: 历史日推只列在线日期)
  final LocalDaysLoader? loadLocalDays;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('每日推荐'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '推荐歌曲'),
              Tab(text: '推荐歌单'),
              Tab(text: '历史日推'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _DailySongsTab(load: loadSongs, onPlay: onPlaySongs),
            _DailyPlaylistsTab(load: loadPlaylists, onOpen: onOpenPlaylist),
            _HistoryTab(
              loadDates: loadHistoryDates,
              loadSongs: loadHistorySongs,
              loadLocalDays: loadLocalDays,
              onOpenPlaylist: onOpenPlaylist,
              onPlay: onPlaySongs,
            ),
          ],
        ),
      ),
    );
  }
}

class _DailySongsTab extends StatefulWidget {
  const _DailySongsTab({required this.load, required this.onPlay});

  final SongListLoader load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  State<_DailySongsTab> createState() => _DailySongsTabState();
}

class _DailySongsTabState extends State<_DailySongsTab>
    with AutomaticKeepAliveClientMixin {
  List<rust.SongDto>? _songs;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final songs = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _songs = songs);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final songs = _songs;
    if (_error != null) {
      return FullError(message: _error!, onRetry: _load);
    }
    if (songs == null) {
      return const LoadingView();
    }
    if (songs.isEmpty) {
      return const EmptyView(
        icon: Icons.music_note_outlined,
        title: '今天没有推荐歌曲',
      );
    }
    // 非分页: 每日推荐歌曲一次全量返回, 接口无分页
    return ListView.builder(
      itemCount: songs.length,
      itemBuilder: (context, i) {
        final s = songs[i];
        return _SongRow(
          song: s,
          index: i + 1,
          // 每日推荐 tab: "..."菜单同样允许"不感兴趣"
          // 行尾不再放"不感兴趣"按钮: 它占掉 ~48dp 横向空间, 而同一动作
          // 已经在行尾「...」菜单里(SongActionSource.dailyRecommend 决定显示)。
          source: SongActionSource.dailyRecommend,
          // 点歌只开始播放, **不退出日推页**: 之前 `Navigator.pop` 会直接
          // 把整页弹掉, 用户想接着挑下一首还得重新进来(用户反馈)。与歌单详情页
          // (detail_page)一致: 列表页点播 = 换队列, 页面留在原地。
          onTap: s.playable ? () => widget.onPlay(songs, i) : null,
        );
      },
    );
  }
}

/// 本地缓存的每日推荐歌单(来自 daily_cache.dart); null/不传 = 不合并本地.
typedef LocalDaysLoader = Future<List<DailyCacheDay>> Function();

/// 历史日推的一行: 在线日期 / 本地缓存日期 / 两者都有(合并去重后只留一行).
class _HistoryEntry {
  const _HistoryEntry({
    required this.date,
    required this.remote,
    required this.local,
  });

  /// YYYY-MM-DD
  final String date;

  /// 服务端历史日推里有这一天(VIP 才能取到曲目)
  final bool remote;

  /// 这一天本地缓存的推荐歌单(可能为空)
  final List<rust.Playlist> local;

  bool get hasLocal => local.isNotEmpty;
}

class _HistoryTab extends StatefulWidget {
  const _HistoryTab({
    required this.loadDates,
    required this.loadSongs,
    required this.onPlay,
    this.loadLocalDays,
    this.onOpenPlaylist,
  });

  final DateListLoader loadDates;
  final HistorySongsLoader loadSongs;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  /// 本地缓存的天(设置里关掉缓存时由上层传 null)
  final LocalDaysLoader? loadLocalDays;

  /// 本地日期下点歌单(不传则该行不可点)
  final void Function(rust.Playlist playlist)? onOpenPlaylist;

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab>
    with AutomaticKeepAliveClientMixin {
  List<String>? _remoteDates;
  List<DailyCacheDay> _localDays = const [];

  /// 在线历史日推的错误: 本地还有内容时降级成列表顶部一行提示, 不整屏报错
  String? _remoteError;

  String? _error;
  Future<void> Function()? _retry;

  /// 选中的日期(非空时展示那一天的曲目/本地歌单)
  _HistoryEntry? _selected;
  List<rust.SongDto>? _songs;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadDates();
  }

  /// 在线日期与本地缓存并行加载: 本地读盘失败只是"少几行", 不能拖垮整页.
  Future<void> _loadDates() async {
    setState(() {
      _error = null;
      _retry = _loadDates;
    });
    final localLoader = widget.loadLocalDays;
    final localFuture = localLoader == null
        ? Future<List<DailyCacheDay>>.value(const <DailyCacheDay>[])
        : localLoader().catchError((_) => const <DailyCacheDay>[]);
    String? remoteError;
    List<String>? dates;
    try {
      dates = await retryNetwork(widget.loadDates);
    } catch (e) {
      remoteError = friendlyError(e);
    }
    final local = await localFuture;
    if (!mounted) return;
    setState(() {
      _remoteDates = dates;
      _localDays = local;
      _remoteError = remoteError;
      // 在线侧失败且本地也没有缓存时才整屏报错(带重试按钮)。
      _error = (dates == null && local.isEmpty) ? remoteError : null;
    });
  }

  /// 打开某一天. 在线日期取曲目; 纯本地日期直接展示缓存的推荐歌单.
  Future<void> _openDay(_HistoryEntry entry) async {
    setState(() {
      _selected = entry;
      _songs = null;
      _error = null;
      _retry = null;
    });
    if (!entry.remote) return;
    try {
      final songs = await retryNetwork(() => widget.loadSongs(entry.date));
      if (!mounted || _selected != entry) return;
      setState(() => _songs = songs);
    } catch (e) {
      if (!mounted || _selected != entry) return;
      setState(() {
        _error = friendlyError(e);
        _retry = () => _openDay(entry);
      });
    }
  }

  void _closeDay() {
    setState(() {
      _selected = null;
      _songs = null;
      _error = null;
      _retry = null;
    });
  }

  /// 在线日期 + 本地缓存按日期合并去重(同一天只留一行), 日期倒序.
  static List<_HistoryEntry> _merge(
    List<String> remote,
    List<DailyCacheDay> local,
  ) {
    final byDate = <String, _HistoryEntry>{};
    for (final raw in remote) {
      final date = raw.trim();
      if (date.isEmpty) continue;
      byDate[date] = _HistoryEntry(date: date, remote: true, local: const []);
    }
    for (final day in local) {
      final existing = byDate[day.date];
      byDate[day.date] = _HistoryEntry(
        date: day.date,
        remote: existing?.remote ?? false,
        local: day.playlists,
      );
    }
    return byDate.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  }

  static String _subtitleOf(_HistoryEntry entry) {
    if (entry.remote) {
      return entry.hasLocal ? '查看这一天的每日推荐(含本地缓存歌单)' : '查看这一天的每日推荐';
    }
    return '本地缓存的每日推荐歌单';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 审查 P1-7.14: 「某一天的日推」是本页内部的二级层级,
    // 系统返回键 / AppBar 返回箭头都应先退回日期列表, 而不是直接关掉整页。
    return PopScope(
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _selected == null) return;
        _closeDay();
      },
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final selected = _selected;
    if (selected != null) return _buildDay(context, selected);
    if (_error != null) {
      final retry = _retry;
      return retry == null
          ? const SizedBox.shrink()
          : FullError(message: _error!, onRetry: retry);
    }
    final remote = _remoteDates;
    // 在线日期没回来、本地也还没读到、也没有错误: 首屏加载态
    if (remote == null && _localDays.isEmpty && _remoteError == null) {
      return const LoadingView();
    }
    final entries = _merge(remote ?? const [], _localDays);
    if (entries.isEmpty) {
      return const EmptyView(
        icon: Icons.vpn_key_outlined,
        title: '最近 5 次日推仅黑胶 VIP 可见\n(开通后明天再来就会出现在这里)',
      );
    }
    final hasRemoteError = _remoteError != null;
    // 非分页: 在线最近 5 次 + 本地缓存天, 条数有限
    return ListView.separated(
      itemCount: entries.length + (hasRemoteError ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (hasRemoteError && i == 0) {
          return ListTile(
            leading: const Icon(Icons.cloud_off_outlined),
            title: const Text('在线历史日推获取失败'),
            subtitle: Text(_remoteError!),
            trailing: TextButton(
              onPressed: _loadDates,
              child: const Text('重试'),
            ),
          );
        }
        final entry = entries[hasRemoteError ? i - 1 : i];
        return ListTile(
          leading: Icon(
            entry.remote ? Icons.history : Icons.offline_pin_outlined,
          ),
          title: Row(
            children: [
              Text(entry.date),
              if (entry.hasLocal) ...[
                const SizedBox(width: 8),
                const _LocalBadge(),
              ],
            ],
          ),
          subtitle: Text(_subtitleOf(entry)),
          onTap: () => _openDay(entry),
        );
      },
    );
  }

  Widget _buildDay(BuildContext context, _HistoryEntry entry) {
    if (_error != null) {
      final retry = _retry;
      return retry == null
          ? const SizedBox.shrink()
          : FullError(message: _error!, onRetry: retry);
    }
    final songs = _songs;
    if (entry.remote && songs == null) {
      return const LoadingView();
    }
    final playlists = entry.local;
    final openPlaylist = widget.onOpenPlaylist;
    final rows = <Widget>[];
    if (entry.remote) {
      final list = songs ?? const <rust.SongDto>[];
      if (list.isEmpty) {
        rows.add(const ListTile(dense: true, title: Text('这一天没有记录')));
      }
      for (var i = 0; i < list.length; i++) {
        final s = list[i];
        rows.add(
          _SongRow(
            song: s,
            index: i + 1,
            // 同「推荐歌曲」页签: 点播不退出历史日推列表
            onTap: s.playable ? () => widget.onPlay(list, i) : null,
          ),
        );
      }
    }
    if (playlists.isNotEmpty) {
      rows.add(
        ListTile(
          dense: true,
          title: Text(
            '本地缓存的推荐歌单(${playlists.length})',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      );
      for (final pl in playlists) {
        rows.add(
          ListTile(
            leading: CoverArt(url: pl.coverUrl, size: 48, radius: 6),
            title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${pl.trackCount} 首'),
            onTap: openPlaylist == null
                ? null
                : () {
                    Navigator.pop(context);
                    openPlaylist(pl);
                  },
          ),
        );
      }
    }
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: IconButton(
            tooltip: '返回日期列表',
            icon: const Icon(Icons.arrow_back),
            onPressed: _closeDay,
          ),
          title: Text('${entry.date} 的日推'),
          subtitle: Text(
            entry.remote
                ? (playlists.isEmpty
                      ? '${songs!.length} 首'
                      : '${songs!.length} 首 · 本地缓存 ${playlists.length} 个歌单')
                : '本地缓存 ${playlists.length} 个歌单',
          ),
        ),
        const Divider(height: 1),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }
}

/// 「本地」标记: 这一天的内容来自本地缓存(设置里关掉缓存后不会出现).
class _LocalBadge extends StatelessWidget {
  const _LocalBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '本地',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}

class _DailyPlaylistsTab extends StatefulWidget {
  const _DailyPlaylistsTab({required this.load, required this.onOpen});

  final PlaylistListLoader load;
  final void Function(rust.Playlist playlist) onOpen;

  @override
  State<_DailyPlaylistsTab> createState() => _DailyPlaylistsTabState();
}

class _DailyPlaylistsTabState extends State<_DailyPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  List<rust.Playlist>? _lists;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final lists = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _lists = lists);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final lists = _lists;
    if (_error != null) {
      return FullError(message: '推荐歌单需要登录后才能获取\n$_error', onRetry: _load);
    }
    if (lists == null) {
      return const LoadingView();
    }
    if (lists.isEmpty) {
      return const EmptyView(
        icon: Icons.queue_music_outlined,
        title: '今天没有推荐歌单',
      );
    }
    // 非分页: 推荐歌单随一次请求全量返回, 接口无分页
    return ListView.builder(
      itemCount: lists.length,
      itemBuilder: (context, i) {
        final pl = lists[i];
        return ListTile(
          leading: CoverArt(url: pl.coverUrl, size: 48, radius: 6),
          title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${pl.trackCount} 首'),
          onTap: () {
            Navigator.pop(context);
            widget.onOpen(pl);
          },
        );
      },
    );
  }
}

typedef AlbumListLoader = Future<List<rust.AlbumItem>> Function();
typedef PodcastListLoader = Future<List<rust.PodcastRadio>> Function();

/// 最近听过: 单曲 / 专辑 / 歌单 / 播客 四个分类.
/// 都来自服务端播放记录(需登录), 未登录时由调用方回落到本地历史.
///
/// 审查 §5.6: 4 个列表放进 72% 高的 sheet 同样局促, 改为全页 [Scaffold]。
Future<void> showRecentPage(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  SongListLoader? loadRecent,
  AlbumListLoader? loadAlbums,
  PlaylistListLoader? loadPlaylists,
  PodcastListLoader? loadPodcasts,
  void Function(rust.Playlist playlist)? onOpenPlaylist,
  void Function(rust.PodcastRadio radio)? onOpenPodcast,
  void Function(rust.AlbumItem album)? onOpenAlbum,
}) {
  final songs = loadRecent ?? () => rust.recentSongs(limit: 100);
  final albums = loadAlbums ?? () => rust.recentAlbums(limit: 100);
  final playlists = loadPlaylists ?? () => rust.recentPlaylists(limit: 100);
  final podcasts = loadPodcasts ?? () => rust.recentPodcasts(limit: 100);
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => RecentPlayedPage(
        loadRecent: songs,
        loadAlbums: albums,
        loadPlaylists: playlists,
        loadPodcasts: podcasts,
        onPlay: onPlay,
        onOpenPlaylist: onOpenPlaylist,
        onOpenPodcast: onOpenPodcast,
        onOpenAlbum: onOpenAlbum,
      ),
    ),
  );
}

/// 最近听过全页(原 showRecentSheet 的弹层内容)。
class RecentPlayedPage extends StatelessWidget {
  const RecentPlayedPage({
    super.key,
    required this.loadRecent,
    required this.loadAlbums,
    required this.loadPlaylists,
    required this.loadPodcasts,
    required this.onPlay,
    this.onOpenPlaylist,
    this.onOpenPodcast,
    this.onOpenAlbum,
  });

  final SongListLoader loadRecent;
  final AlbumListLoader loadAlbums;
  final PlaylistListLoader loadPlaylists;
  final PodcastListLoader loadPodcasts;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final void Function(rust.Playlist playlist)? onOpenPlaylist;
  final void Function(rust.PodcastRadio radio)? onOpenPodcast;
  final void Function(rust.AlbumItem album)? onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    // 字段是 public 的, 不能直接靠 null 检查做类型提升 —— 提到局部变量
    final openAlbum = onOpenAlbum;
    final openPlaylist = onOpenPlaylist;
    final openPodcast = onOpenPodcast;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('最近听过'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '单曲'),
              Tab(text: '专辑'),
              Tab(text: '歌单'),
              Tab(text: '播客'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _RecentBucketTab<rust.SongDto>(
              load: loadRecent,
              emptyText: '还没有最近听过的单曲\n(登录后会自动同步服务端记录)',
              itemBuilder: (context, s, i, list) => _SongRow(
                song: s,
                index: i + 1,
                // 与其它全页列表一致: 点播换队列, 不退出"最近听过"
                onTap: s.playable
                    ? () => onPlay(list.cast<rust.SongDto>(), i)
                    : null,
              ),
            ),
            _RecentBucketTab<rust.AlbumItem>(
              load: loadAlbums,
              emptyText: '还没有最近听过的专辑',
              itemBuilder: (context, a, i, _) => ListTile(
                leading: CoverArt(url: a.coverUrl, size: 48, radius: 6),
                title: Text(
                  a.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  a.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: openAlbum == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        openAlbum(a);
                      },
              ),
            ),
            _RecentBucketTab<rust.Playlist>(
              load: loadPlaylists,
              emptyText: '还没有最近听过的歌单',
              itemBuilder: (context, pl, i, _) => ListTile(
                leading: CoverArt(url: pl.coverUrl, size: 48, radius: 6),
                title: AdaptiveText(pl.name),
                subtitle: pl.trackCount > BigInt.zero
                    ? Text('${pl.trackCount} 首')
                    : null,
                onTap: openPlaylist == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        openPlaylist(pl);
                      },
              ),
            ),
            _RecentBucketTab<rust.PodcastRadio>(
              load: loadPodcasts,
              emptyText: '还没有最近听过的播客',
              itemBuilder: (context, r, i, _) => ListTile(
                leading: CoverArt(url: r.coverUrl, size: 48, radius: 6),
                title: AdaptiveText(r.name),
                subtitle: Text(
                  [
                    if (r.djName.isNotEmpty) r.djName,
                    if (r.programCount > BigInt.zero) '${r.programCount} 集',
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: openPodcast == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        openPodcast(r);
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 一个分类的列表: 自己加载 + 自己保活, 切 tab 不重新请求.
class _RecentBucketTab<T> extends StatefulWidget {
  const _RecentBucketTab({
    required this.load,
    required this.emptyText,
    required this.itemBuilder,
  });

  final Future<List<T>> Function() load;
  final String emptyText;

  /// 第四个参数是整份列表(点播单曲需要用它重置队列)
  final Widget Function(BuildContext context, T item, int index, List<T> list)
  itemBuilder;

  @override
  State<_RecentBucketTab<T>> createState() => _RecentBucketTabState<T>();
}

class _RecentBucketTabState<T> extends State<_RecentBucketTab<T>>
    with AutomaticKeepAliveClientMixin {
  List<T>? _items;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final items = await retryNetwork(widget.load);
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_error != null) {
      return FullError(message: _error!, onRetry: _load);
    }
    final items = _items;
    if (items == null) {
      return const LoadingView();
    }
    if (items.isEmpty) {
      return EmptyView(title: widget.emptyText);
    }
    // 非分页: 单次取全(load 一次拿完), 无更多页
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) =>
          widget.itemBuilder(context, items[i], i, items),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.song,
    required this.index,
    required this.onTap,
    this.source = SongActionSource.other,
  });

  final rust.SongDto song;
  final int index;
  final VoidCallback? onTap;

  /// 菜单来源(决定"..."菜单里"不感兴趣"是否显示)
  final SongActionSource source;

  @override
  Widget build(BuildContext context) {
    // 用户反馈(2026-11-14): 完整日推歌单里正在播放的那首没有高亮。
    // 现在统一读全局"正在播放"(src/now_playing.dart): 命中就把序号换成喇叭、
    // 歌名换成主色, 与歌单详情页/搜索结果同一套播放态语汇。
    return NowPlayingHighlight(
      songId: song.id,
      builder: (context, playing) => _buildRow(context, playing),
    );
  }

  Widget _buildRow(BuildContext context, bool playing) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    return ListTile(
      dense: true,
      selected: playing,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            // token-ok: 序号列宽按 "两位数" 内容宽度定, 不是间距 token
            width: 22,
            child: playing
                ? Icon(Icons.volume_up, size: 16, color: scheme.primary)
                : Text('$index', style: theme.bodySmall),
          ),
          CoverArt(url: song.coverUrl, size: 40, radius: 4),
        ],
      ),
      // 歌名 + VIP/付费/无版权标记(标记固定宽度, 不会被歌名挤掉)
      title: SongTitleWithBadges(
        song: song,
        style: playing
            ? theme.bodyMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              )
            : (song.playable ? null : TextStyle(color: scheme.outline)),
      ),
      subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: SongOverflowButton(song: song, size: 20, source: source),
      onTap: onTap,
    );
  }
}
