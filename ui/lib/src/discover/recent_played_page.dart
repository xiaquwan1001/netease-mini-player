import 'package:flutter/material.dart';

import '../adaptive_text.dart';
import '../cover_art.dart';
import '../error_views.dart' show FullError;
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../state_views.dart';
import 'discover_song_row.dart' show DiscoverSongRow;
import 'discover_types.dart';

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
              itemBuilder: (context, s, i, list) => DiscoverSongRow(
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
