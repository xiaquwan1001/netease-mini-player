import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';

/// 相似歌曲面板: 上半是相似歌曲(点击整批起播), 下半是相似歌单.
///
/// 数据: simi_song / simi_playlist(都以 song id 为种子)
typedef SimilarSongsLoader = Future<List<rust.SongDto>> Function(
    BigInt songId, int limit);
typedef SimilarPlaylistsLoader = Future<List<rust.PlaylistDto>> Function(
    BigInt songId, int limit);

Future<void> showSimilarSongs(
  BuildContext context, {
  required rust.SongDto song,
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  required void Function(rust.PlaylistDto playlist) onOpenPlaylist,
  SimilarSongsLoader? loadSongs,
  SimilarPlaylistsLoader? loadPlaylists,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.8,
        child: _SimilarSheet(
          song: song,
          onPlay: onPlay,
          onOpenPlaylist: onOpenPlaylist,
          loadSongs: loadSongs ?? (id, limit) => rust.similarSongs(songId: id, limit: limit),
          loadPlaylists:
              loadPlaylists ?? (id, limit) => rust.similarPlaylists(songId: id, limit: limit),
        ),
      ),
    ),
  );
}

class _SimilarSheet extends StatefulWidget {
  const _SimilarSheet({
    required this.song,
    required this.onPlay,
    required this.onOpenPlaylist,
    required this.loadSongs,
    required this.loadPlaylists,
  });

  final rust.SongDto song;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final void Function(rust.PlaylistDto playlist) onOpenPlaylist;
  final SimilarSongsLoader loadSongs;
  final SimilarPlaylistsLoader loadPlaylists;

  @override
  State<_SimilarSheet> createState() => _SimilarSheetState();
}

class _SimilarSheetState extends State<_SimilarSheet> {
  List<rust.SongDto>? _songs;
  List<rust.PlaylistDto>? _playlists;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait([
        retryNetwork(() => widget.loadSongs(widget.song.id, 30)),
        retryNetwork(() => widget.loadPlaylists(widget.song.id, 12)),
      ]);
      if (!mounted) return;
      setState(() {
        _songs = results[0] as List<rust.SongDto>;
        _playlists = results[1] as List<rust.PlaylistDto>;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final songs = _songs;
    final playlists = _playlists;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(
            children: [
              CoverArt(url: widget.song.coverUrl, size: 40, radius: 4),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '和《${widget.song.name}》相似',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      widget.song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          )
        else if (songs == null)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                if (songs.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('没有找到相似歌曲', style: theme.textTheme.bodySmall),
                  ),
                for (var i = 0; i < songs.length; i++)
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    leading: CoverArt(url: songs[i].coverUrl, size: 40, radius: 4),
                    title: Text(
                      songs[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      songs[i].artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: SongOverflowButton(song: songs[i], size: 20),
                    onTap: songs[i].playable
                        ? () {
                            Navigator.pop(context);
                            widget.onPlay(songs, i);
                          }
                        : null,
                  ),
                if (playlists != null && playlists.isNotEmpty) ...[
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: Text(
                      '相似歌单',
                      style: theme.textTheme.labelLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  SizedBox(
                    height: 150,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: playlists.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final pl = playlists[i];
                        return SizedBox(
                          width: 100,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              Navigator.pop(context);
                              widget.onOpenPlaylist(pl);
                            },
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CoverArt(url: pl.coverUrl, size: 100, radius: 8),
                                const SizedBox(height: 4),
                                Text(
                                  pl.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelSmall,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}
