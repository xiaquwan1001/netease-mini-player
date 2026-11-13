import 'package:flutter/material.dart';

import 'async_view.dart';
import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'section_header.dart';
import 'toast.dart' show showToast;

/// 曲风详情页: 系统推荐给"我"的风格下面有哪些歌单和歌.
///
/// 入口在推荐页的"风格推荐"(见 recommend_view.dart), 数据来自
/// /api/style-tag/home/{song,playlist}(见 ncm-service)。
typedef StyleSongsLoader = Future<List<rust.SongDto>> Function(String tagId);
typedef StylePlaylistsLoader = Future<List<rust.Playlist>> Function(
  String tagId,
);

Future<void> showStyleDetail(
  BuildContext context, {
  required rust.StyleTag tag,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  required void Function(rust.Playlist playlist) onOpenPlaylist,
  StyleSongsLoader? loadSongs,
  StylePlaylistsLoader? loadPlaylists,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(tag.name)),
        body: StyleDetailView(
          tag: tag,
          onPlaySongs: onPlaySongs,
          onOpenPlaylist: onOpenPlaylist,
          loadSongs: loadSongs,
          loadPlaylists: loadPlaylists,
        ),
      ),
    ),
  );
}

class StyleDetailView extends StatefulWidget {
  const StyleDetailView({
    super.key,
    required this.tag,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
    this.loadSongs,
    this.loadPlaylists,
  });

  final rust.StyleTag tag;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;
  final StyleSongsLoader? loadSongs;
  final StylePlaylistsLoader? loadPlaylists;

  @override
  State<StyleDetailView> createState() => _StyleDetailViewState();
}

class _StyleDetailViewState extends State<StyleDetailView> {
  StyleSongsLoader get _songs =>
      widget.loadSongs ?? (tagId) => rust.styleSongs(tagId: tagId, limit: 50);
  StylePlaylistsLoader get _playlists =>
      widget.loadPlaylists ??
      (tagId) => rust.stylePlaylists(tagId: tagId, limit: 20);

  late Future<List<rust.SongDto>> _songsFuture;
  late Future<List<rust.Playlist>> _playlistsFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _songsFuture = retryNetwork(() => _songs(widget.tag.id));
    _playlistsFuture = retryNetwork(() => _playlists(widget.tag.id));
  }

  /// 下拉刷新: 已有数据时不走 FutureBuilder 重置(避免清空/闪烁),
  /// 只有全部成功才替换数据; 失败只提示, 保留旧内容。
  Future<void> _refresh() async {
    try {
      final songs = await retryNetwork(() => _songs(widget.tag.id));
      final playlists = await retryNetwork(() => _playlists(widget.tag.id));
      if (!mounted) return;
      setState(() {
        _songsFuture = Future.value(songs);
        _playlistsFuture = Future.value(playlists);
      });
    } catch (e) {
      if (!mounted) return;
      showToast(context, friendlyError(e), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _StyleHeader(tag: widget.tag),
          const SizedBox(height: 12),
          // 风格歌单/风格歌曲是**页面级区块标题**(原来是 titleMedium + 底 8dp),
          // 用 SectionHeader 而不是 SectionTitle(小组标题 titleSmall), 保持原字号。
          SectionHeader(
            title: '风格歌单',
            trailing: widget.tag.songCount == null
                ? null
                : Text(
                    '共 ${widget.tag.songCount} 首',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
          ),
          _PlaylistRow(
            future: _playlistsFuture,
            onOpen: widget.onOpenPlaylist,
            onRetry: () => setState(_reload),
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: '风格歌曲'),
          _SongList(
            future: _songsFuture,
            onPlay: widget.onPlaySongs,
            onRetry: () => setState(_reload),
          ),
        ],
      ),
    );
  }
}

class _StyleHeader extends StatelessWidget {
  const _StyleHeader({required this.tag});

  final rust.StyleTag tag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            if (tag.coverUrl != null)
              CoverArt(url: tag.coverUrl, size: 56, radius: 8)
            else
              CircleAvatar(
                radius: 28,
                backgroundColor: scheme.primaryContainer,
                child: Icon(Icons.piano, color: scheme.primary),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tag.name,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '系统按你的听歌口味推荐',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.future,
    required this.onOpen,
    required this.onRetry,
  });

  final Future<List<rust.Playlist>> future;
  final void Function(rust.Playlist playlist) onOpen;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // future 由父层持有(下拉刷新换 Future.value 不闪加载态) ⇒ 走 AsyncView 的
    // future 分支, 四态判定仍然只有 async_view.dart 一份实现。
    return AsyncView<List<rust.Playlist>>(
      future: future,
      onRetry: onRetry,
      emptyText: '这个风格暂时没有歌单',
      builder: (context, lists, _) {
        return SizedBox(
          height: 176,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: lists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (_, i) {
              final pl = lists[i];
              return SizedBox(
                width: 118,
                child: InkWell(
                  onTap: () => onOpen(pl),
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CoverArt(url: pl.coverUrl, size: 118, radius: 8),
                      const SizedBox(height: 4),
                      Text(
                        pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      Text(
                        '${pl.trackCount} 首',
                        maxLines: 1,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

class _SongList extends StatelessWidget {
  const _SongList({
    required this.future,
    required this.onPlay,
    required this.onRetry,
  });

  final Future<List<rust.SongDto>> future;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<rust.SongDto>>(
      future: future,
      onRetry: onRetry,
      emptyText: '这个风格暂时没有歌曲',
      builder: (context, songs, _) {
        // 空态已由 AsyncView 统一处理(emptyText), 这里不再重复判定
        final playable = [
          for (final s in songs)
            if (s.playable) s,
        ];
        return Card(
          margin: EdgeInsets.zero,
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in songs)
                ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: CoverArt(url: s.coverUrl, size: 40, radius: 4),
                  title: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    s.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: s.playable
                      ? () {
                          final index = playable.indexWhere(
                            (x) => x.id == s.id,
                          );
                          onPlay(playable, index < 0 ? 0 : index);
                        }
                      : null,
                ),
            ],
          ),
        );
      },
    );
  }
}
