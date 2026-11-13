import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'error_views.dart' show FullError;
import 'song_actions.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'state_views.dart';
import 'toast.dart' show showToastWith;

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

  /// 每日推荐里"不感兴趣"(不传就不显示那个按钮)
  Future<void> Function(rust.SongDto song)? onDislike,
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
        onPlaySongs: onPlaySongs,
        onOpenPlaylist: onOpenPlaylist,
        onDislike: onDislike,
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
    this.onDislike,
  });

  final SongListLoader loadSongs;
  final PlaylistListLoader loadPlaylists;
  final DateListLoader loadHistoryDates;
  final HistorySongsLoader loadHistorySongs;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;
  final Future<void> Function(rust.SongDto song)? onDislike;

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
            _DailySongsTab(
              load: loadSongs,
              onPlay: onPlaySongs,
              onDislike: onDislike,
            ),
            _DailyPlaylistsTab(load: loadPlaylists, onOpen: onOpenPlaylist),
            _HistoryTab(
              loadDates: loadHistoryDates,
              loadSongs: loadHistorySongs,
              onPlay: onPlaySongs,
            ),
          ],
        ),
      ),
    );
  }
}

class _DailySongsTab extends StatefulWidget {
  const _DailySongsTab({
    required this.load,
    required this.onPlay,
    this.onDislike,
  });

  final SongListLoader load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final Future<void> Function(rust.SongDto song)? onDislike;

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
          source: SongActionSource.dailyRecommend,
          trailing: widget.onDislike == null
              ? null
              : IconButton(
                  tooltip: '不感兴趣',
                  icon: const Icon(Icons.do_not_disturb_on_outlined, size: 20),
                  onPressed: () => _dislike(s),
                ),
          onTap: s.playable
              ? () {
                  Navigator.pop(context);
                  widget.onPlay(songs, i);
                }
              : null,
        );
      },
    );
  }

  /// 不感兴趣: 调接口成功后从本地列表里去掉(以后不会再被推)
  Future<void> _dislike(rust.SongDto song) async {
    final handler = widget.onDislike;
    if (handler == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await handler(song);
      if (!mounted) return;
      setState(() => _songs?.removeWhere((s) => s.id == song.id));
      if (messenger != null) {
        showToastWith(messenger, '已减少《${song.name}》这类推荐');
      }
    } catch (e) {
      if (messenger != null) {
        showToastWith(messenger, '操作失败: ${friendlyError(e)}', isError: true);
      }
    }
  }
}

class _HistoryTab extends StatefulWidget {
  const _HistoryTab({
    required this.loadDates,
    required this.loadSongs,
    required this.onPlay,
  });

  final DateListLoader loadDates;
  final HistorySongsLoader loadSongs;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab>
    with AutomaticKeepAliveClientMixin {
  List<String>? _dates;
  String? _error;

  /// 选中的日期(非空时展示那一天的歌单)
  String? _date;
  List<rust.SongDto>? _songs;
  Future<void> Function()? _retry;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadDates();
  }

  Future<void> _loadDates() async {
    setState(() {
      _error = null;
      _retry = _loadDates;
    });
    try {
      final dates = await retryNetwork(widget.loadDates);
      if (!mounted) return;
      setState(() => _dates = dates);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _loadSongs(String date) async {
    setState(() {
      _date = date;
      _songs = null;
      _error = null;
      _retry = () => _loadSongs(date);
    });
    try {
      final songs = await retryNetwork(() => widget.loadSongs(date));
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
    // 审查 P1-7.14: 「某一天的日推」是本页内部的二级层级,
    // 系统返回键 / AppBar 返回箭头都应先退回日期列表, 而不是直接关掉整页。
    return PopScope(
      canPop: _date == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _date == null) return;
        setState(() {
          _date = null;
          _songs = null;
        });
      },
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_error != null) {
      final retry = _retry;
      return retry == null
          ? const SizedBox.shrink()
          : FullError(message: _error!, onRetry: retry);
    }
    // 已选日期: 展示那天推荐的歌
    if (_date != null) {
      final songs = _songs;
      if (songs == null) {
        return const LoadingView();
      }
      return Column(
        children: [
          ListTile(
            dense: true,
            leading: IconButton(
              tooltip: '返回日期列表',
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() {
                _date = null;
                _songs = null;
              }),
            ),
            title: Text('$_date 的日推'),
            subtitle: Text('${songs.length} 首'),
          ),
          const Divider(height: 1),
          // 非分页: 某日日推歌曲一次全量返回, 接口无分页
          Expanded(
            child: songs.isEmpty
                ? const Center(child: Text('这一天没有记录'))
                : ListView.builder(
                    itemCount: songs.length,
                    itemBuilder: (context, i) {
                      final s = songs[i];
                      return _SongRow(
                        song: s,
                        index: i + 1,
                        onTap: s.playable
                            ? () {
                                Navigator.pop(context);
                                widget.onPlay(songs, i);
                              }
                            : null,
                      );
                    },
                  ),
          ),
        ],
      );
    }
    final dates = _dates;
    if (dates == null) {
      return const LoadingView();
    }
    if (dates.isEmpty) {
      return const EmptyView(
        icon: Icons.vpn_key_outlined,
        title: '最近 5 次日推仅黑胶 VIP 可见\n(开通后明天再来就会出现在这里)',
      );
    }
    // 非分页: 最近 5 次日推, 固定条数
    return ListView.separated(
      itemCount: dates.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final d = dates[i];
        return ListTile(
          leading: const Icon(Icons.history),
          title: Text(d),
          subtitle: const Text('查看这一天的每日推荐'),
          onTap: () => _loadSongs(d),
        );
      },
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
                onTap: s.playable
                    ? () {
                        Navigator.pop(context);
                        onPlay(list.cast<rust.SongDto>(), i);
                      }
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
                title: Text(
                  pl.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
                title: Text(
                  r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
    this.trailing,
    this.source = SongActionSource.other,
  });

  final rust.SongDto song;
  final int index;
  final VoidCallback? onTap;

  /// 行尾附加按钮(每日推荐的"不感兴趣")
  final Widget? trailing;

  /// 菜单来源(决定"..."菜单里"不感兴趣"是否显示)
  final SongActionSource source;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      dense: true,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            child: Text('$index', style: Theme.of(context).textTheme.bodySmall),
          ),
          CoverArt(url: song.coverUrl, size: 40, radius: 4),
        ],
      ),
      // 歌名 + VIP/付费/无版权标记(标记固定宽度, 不会被歌名挤掉)
      title: SongTitleWithBadges(
        song: song,
        style: song.playable ? null : TextStyle(color: scheme.outline),
      ),
      subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?trailing,
          SongOverflowButton(song: song, size: 20, source: source),
        ],
      ),
      onTap: onTap,
    );
  }
}
