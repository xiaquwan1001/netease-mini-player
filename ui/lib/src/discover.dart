import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';

typedef SongListLoader = Future<List<rust.SongDto>> Function();
typedef PlaylistListLoader = Future<List<rust.PlaylistDto>> Function();

/// 每日推荐(原版): 推荐歌曲 + 推荐歌单两个页签.
/// loadSongs/loadPlaylists 可注入(测试用), 默认走 Rust 接口.
Future<void> showDiscoverSheet(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  required void Function(rust.PlaylistDto playlist) onOpenPlaylist,
  SongListLoader? loadSongs,
  PlaylistListLoader? loadPlaylists,
}) {
  final songs = loadSongs ?? rust.dailyRecommendSongs;
  final playlists = loadPlaylists ?? rust.dailyRecommendPlaylists;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => DefaultTabController(
      length: 2,
      child: SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.72,
          child: Column(
            children: [
              SheetHeader(
                title: '每日推荐',
                onClose: () => Navigator.pop(sheetContext),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '推荐歌曲'),
                  Tab(text: '推荐歌单'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _DailySongsTab(load: songs, onPlay: onPlaySongs),
                    _DailyPlaylistsTab(load: playlists, onOpen: onOpenPlaylist),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
      return _ErrorView(message: _error!, onRetry: _load);
    }
    if (songs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (songs.isEmpty) {
      return const Center(child: Text('今天没有推荐歌曲'));
    }
    return ListView.builder(
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
    );
  }
}

class _DailyPlaylistsTab extends StatefulWidget {
  const _DailyPlaylistsTab({required this.load, required this.onOpen});

  final PlaylistListLoader load;
  final void Function(rust.PlaylistDto playlist) onOpen;

  @override
  State<_DailyPlaylistsTab> createState() => _DailyPlaylistsTabState();
}

class _DailyPlaylistsTabState extends State<_DailyPlaylistsTab>
    with AutomaticKeepAliveClientMixin {
  List<rust.PlaylistDto>? _lists;
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
      return _ErrorView(
        message: '推荐歌单需要登录后才能获取\n$_error',
        onRetry: _load,
      );
    }
    if (lists == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (lists.isEmpty) {
      return const Center(child: Text('今天没有推荐歌单'));
    }
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

/// 最近听过(登录时服务端记录, 否则本地播放历史)
Future<void> showRecentSheet(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  SongListLoader? loadRecent,
}) {
  final load = loadRecent ?? () => rust.recentSongs(limit: 100);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.of(sheetContext).size.height * 0.7,
        child: Column(
          children: [
            SheetHeader(
              title: '最近听过',
              onClose: () => Navigator.pop(sheetContext),
            ),
            Expanded(child: _RecentList(load: load, onPlay: onPlay)),
          ],
        ),
      ),
    ),
  );
}

class _RecentList extends StatefulWidget {
  const _RecentList({required this.load, required this.onPlay});

  final SongListLoader load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  State<_RecentList> createState() => _RecentListState();
}

class _RecentListState extends State<_RecentList> {
  List<rust.SongDto>? _songs;
  String? _error;

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
    final songs = _songs;
    if (_error != null) {
      return _ErrorView(message: _error!, onRetry: _load);
    }
    if (songs == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (songs.isEmpty) {
      return const Center(
        child: Text('还没有最近听过\n(登录后会自动同步服务端记录)'),
      );
    }
    return ListView.builder(
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
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({
    required this.song,
    required this.index,
    required this.onTap,
  });

  final rust.SongDto song;
  final int index;
  final VoidCallback? onTap;

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
      title: Text(
        song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: song.playable ? null : TextStyle(color: scheme.outline),
      ),
      subtitle: Text(
        song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: song.playable
          ? null
          : Text('无版权', style: Theme.of(context).textTheme.labelSmall),
      onTap: onTap,
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
