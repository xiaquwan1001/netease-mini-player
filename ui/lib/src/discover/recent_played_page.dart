import 'package:flutter/material.dart';

import '../adaptive_text.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../error_views.dart' show FullError;
import '../layout.dart' show kPageRowPadding;
import '../net_retry.dart';
import '../playback_bridge.dart';
import '../rust/api_all.dart' as rust;
import '../state_views.dart';
import '../song_tile.dart' show SongRow;
import 'discover_types.dart';

/// 最近听过: 单曲 / 专辑 / 歌单 / 播客 四个分类.
/// 都来自服务端播放记录(需登录), 未登录时由调用方回落到本地历史.
///
/// 审查 §5.6: 4 个列表放进 72% 高的 sheet 同样局促, 改为全页 [Scaffold]。
Future<void> showRecentPage(
  BuildContext context, {
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
    this.onOpenPlaylist,
    this.onOpenPodcast,
    this.onOpenAlbum,
  });

  final SongListLoader loadRecent;
  final AlbumListLoader loadAlbums;
  final PlaylistListLoader loadPlaylists;
  final PodcastListLoader loadPodcasts;
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
              itemBuilder: (context, s, i, list) => SongRow.pageIndexed(
                song: s,
                indexText: '${i + 1}',
                // 整页铺满列表 + 行首封面: 左 12 与同页专辑/歌单/播客行一致
                // (列表行审计 C 级: SongRow 默认已是 kPageRowPadding 的 12, 与下面三个 tab 共线)
                // 与其它全页列表一致: 点播换队列, 不退出"最近听过"
                onTap: s.playable
                    ? () => PlaybackBridge.instance.playSongs(
                        list.cast<rust.SongDto>(),
                        i,
                      )
                    : null,
              ),
            ),
            _RecentBucketTab<rust.AlbumItem>(
              load: loadAlbums,
              emptyText: '还没有最近听过的专辑',
              itemBuilder: (context, a, i, _) => ListTile(
                // 整页铺满列表: 左 12(列表行审计 C 级)
                contentPadding: kPageRowPadding,
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
                // 整页铺满列表: 左 12(列表行审计 C 级)
                contentPadding: kPageRowPadding,
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
                // 整页铺满列表: 左 12(列表行审计 C 级)
                contentPadding: kPageRowPadding,
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

/// 一个分类的列表: 四态交给 [AsyncView](整页 LoadingView / FullError /
/// EmptyView + keepAlive), 自己只负责条目排版.
///
/// keepAlive 保住"切 tab 再回来不重新请求"的原语义(见 [AsyncView.keepAlive])。
class _RecentBucketTab<T> extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return AsyncView<List<T>>(
      load: load,
      keepAlive: true,
      emptyText: emptyText,
      loadingBuilder: (_) => const LoadingView(),
      emptyBuilder: (_) => EmptyView(title: emptyText),
      errorBuilder: (_, error, retry) =>
          FullError(message: friendlyError(error), onRetry: retry),
      // 非分页: 单次取全(load 一次拿完), 无更多页
      builder: (context, items, _) => ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, i) => itemBuilder(context, items[i], i, items),
      ),
    );
  }
}
