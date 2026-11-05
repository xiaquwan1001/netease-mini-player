import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// "我的": 我喜欢 / 收藏歌单 / 收藏播客 / 关注艺人 / 关注动态.
/// 所有区块独立加载; 未登录时只显示登录引导.
class MineView extends StatefulWidget {
  const MineView({
    super.key,
    required this.loggedIn,
    required this.onLogin,
    required this.onOpenAccounts,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
    required this.onOpenPodcast,
    this.loadLiked,
    this.loadPlaylists,
    this.loadPodcasts,
    this.loadArtists,
    this.loadFeed,
  });

  final bool loggedIn;
  final VoidCallback onLogin;
  final VoidCallback onOpenAccounts;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.PlaylistDto playlist) onOpenPlaylist;
  final void Function(rust.PodcastRadioDto radio) onOpenPodcast;

  final Future<List<rust.SongDto>> Function()? loadLiked;
  final Future<List<rust.PlaylistDto>> Function()? loadPlaylists;
  final Future<List<rust.PodcastRadioDto>> Function()? loadPodcasts;
  final Future<List<rust.ArtistDto>> Function()? loadArtists;
  final Future<List<rust.FeedEventDto>> Function()? loadFeed;

  @override
  State<MineView> createState() => _MineViewState();
}

class _MineViewState extends State<MineView> {
  Future<List<rust.SongDto>> Function() get _liked =>
      widget.loadLiked ?? rust.likedSongs;
  Future<List<rust.PlaylistDto>> Function() get _playlists =>
      widget.loadPlaylists ?? rust.myPlaylists;
  Future<List<rust.PodcastRadioDto>> Function() get _podcasts =>
      widget.loadPodcasts ?? (() => rust.subscribedPodcasts(limit: 50));
  Future<List<rust.ArtistDto>> Function() get _artists =>
      widget.loadArtists ?? (() => rust.subscribedArtists(limit: 50));
  Future<List<rust.FeedEventDto>> Function() get _feed =>
      widget.loadFeed ??
      (() => rust.feedEvents(limit: 20, lastTime: -1));

  @override
  Widget build(BuildContext context) {
    if (!widget.loggedIn) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.account_circle, size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              const Text('登录后查看我喜欢的音乐、收藏歌单/播客和关注动态'),
              const SizedBox(height: 16),
              FilledButton(onPressed: widget.onLogin, child: const Text('登录')),
              TextButton(
                onPressed: widget.onOpenAccounts,
                child: const Text('账号管理'),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _LikedSection(load: _liked, onPlay: widget.onPlaySongs),
          const SizedBox(height: 16),
          _PlaylistsSection(load: _playlists, onOpen: widget.onOpenPlaylist),
          const SizedBox(height: 16),
          _PodcastsSection(load: _podcasts, onOpen: widget.onOpenPodcast),
          const SizedBox(height: 16),
          _ArtistsSection(load: _artists),
          const SizedBox(height: 16),
          _FeedSection(load: _feed, onPlay: widget.onPlaySongs),
        ],
      ),
    );
  }
}

// ---------------- 区块骨架 ----------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _AsyncSection<T> extends StatefulWidget {
  const _AsyncSection({
    required this.load,
    required this.builder,
    required this.emptyText,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, VoidCallback reload) builder;
  final String emptyText;

  @override
  State<_AsyncSection<T>> createState() => _AsyncSectionState<T>();
}

class _AsyncSectionState<T> extends State<_AsyncSection<T>> {
  late Future<T> _future;

  @override
  void initState() {
    super.initState();
    _future = retryNetwork(widget.load);
  }

  void _reload() => setState(() => _future = retryNetwork(widget.load));

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snap.hasError) {
          return _InlineError(
            message: friendlyError(snap.error!),
            onRetry: _reload,
          );
        }
        final data = snap.data;
        if (data == null || (data is List && data.isEmpty)) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              widget.emptyText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        return widget.builder(context, data as T, _reload);
      },
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    );
  }
}

// ---------------- 我喜欢 ----------------

class _LikedSection extends StatelessWidget {
  const _LikedSection({required this.load, required this.onPlay});

  final Future<List<rust.SongDto>> Function() load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '我喜欢的音乐'),
        _AsyncSection<List<rust.SongDto>>(
          load: load,
          emptyText: '还没有喜欢的歌曲',
          builder: (context, songs, reload) {
            final playable = [for (final s in songs) if (s.playable) s];
            final preview = songs.take(8).toList();
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < preview.length; i++)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: CoverArt(url: preview[i].coverUrl, size: 40, radius: 4),
                      title: Text(
                        preview[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        preview[i].artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: songs.length > preview.length && i == preview.length - 1
                          ? Text('共 ${songs.length} 首',
                              style: Theme.of(context).textTheme.labelSmall)
                          : null,
                      onTap: preview[i].playable
                          ? () {
                              final index =
                                  playable.indexWhere((s) => s.id == preview[i].id);
                              onPlay(playable, index < 0 ? 0 : index);
                            }
                          : null,
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

// ---------------- 歌单 / 播客 ----------------

class _PlaylistsSection extends StatelessWidget {
  const _PlaylistsSection({required this.load, required this.onOpen});

  final Future<List<rust.PlaylistDto>> Function() load;
  final void Function(rust.PlaylistDto playlist) onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '收藏的歌单'),
        _AsyncSection<List<rust.PlaylistDto>>(
          load: load,
          emptyText: '还没有收藏歌单',
          builder: (context, lists, reload) => SizedBox(
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: lists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final pl = lists[i];
                return SizedBox(
                  width: 118,
                  child: _CoverCard(
                    coverUrl: pl.coverUrl,
                    title: pl.special ? '我喜欢的音乐' : pl.name,
                    subtitle: '${pl.trackCount} 首',
                    onTap: () => onOpen(pl),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _PodcastsSection extends StatelessWidget {
  const _PodcastsSection({required this.load, required this.onOpen});

  final Future<List<rust.PodcastRadioDto>> Function() load;
  final void Function(rust.PodcastRadioDto radio) onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '收藏的播客'),
        _AsyncSection<List<rust.PodcastRadioDto>>(
          load: load,
          emptyText: '还没有收藏播客',
          builder: (context, radios, reload) => SizedBox(
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: radios.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final r = radios[i];
                return SizedBox(
                  width: 118,
                  child: _CoverCard(
                    coverUrl: r.coverUrl,
                    title: r.name,
                    subtitle: [
                      if (r.djName.isNotEmpty) r.djName,
                      if (r.programCount > BigInt.zero) '${r.programCount} 集',
                    ].join(' · '),
                    onTap: () => onOpen(r),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _CoverCard extends StatelessWidget {
  const _CoverCard({
    required this.coverUrl,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String? coverUrl;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CoverArt(url: coverUrl, size: 118, radius: 8),
          const SizedBox(height: 4),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// ---------------- 关注艺人 ----------------

class _ArtistsSection extends StatelessWidget {
  const _ArtistsSection({required this.load});

  final Future<List<rust.ArtistDto>> Function() load;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '关注的艺人'),
        _AsyncSection<List<rust.ArtistDto>>(
          load: load,
          emptyText: '还没有关注艺人',
          builder: (context, artists, reload) => Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final a in artists)
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: CircleAvatar(
                    child: Text(
                      a.name.characters.first,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  label: Text(a.name),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------- 关注动态 ----------------

class _FeedSection extends StatelessWidget {
  const _FeedSection({required this.load, required this.onPlay});

  final Future<List<rust.FeedEventDto>> Function() load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '关注动态'),
        _AsyncSection<List<rust.FeedEventDto>>(
          load: load,
          emptyText: '关注的艺人/好友还没有新动态',
          builder: (context, events, reload) {
            final songs = [
              for (final e in events)
                if (e.song != null && e.song!.playable) e.song!,
            ];
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final e in events)
                    _FeedTile(
                      event: e,
                      onPlay: e.song == null || !e.song!.playable
                          ? null
                          : () {
                              final index = songs.indexWhere((s) => s.id == e.song!.id);
                              onPlay(songs, index < 0 ? 0 : index);
                            },
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _FeedTile extends StatelessWidget {
  const _FeedTile({required this.event, required this.onPlay});

  final rust.FeedEventDto event;
  final VoidCallback? onPlay;

  String get _kindLabel => switch (event.kind) {
        'song' => '分享了单曲',
        'album' => '分享了专辑',
        'playlist' => '分享了歌单',
        'program' => '分享了节目',
        'text' => '发布了动态',
        _ => '发布了动态',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final song = event.song;
    final body = event.text.isNotEmpty ? event.text : (song?.name ?? '');
    return InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: scheme.surfaceContainerHighest,
              backgroundImage:
                  event.avatarUrl == null ? null : NetworkImage(event.avatarUrl!),
              child: event.avatarUrl == null
                  ? Text(
                      event.userName.isEmpty ? '?' : event.userName.characters.first,
                      style: const TextStyle(fontSize: 12),
                    )
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          event.userName.isEmpty ? '未知用户' : event.userName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .labelLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _kindLabel,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const Spacer(),
                      Text(
                        _relativeTime(event.timeMs),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                  if (body.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (song != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          CoverArt(url: song.coverUrl, size: 40, radius: 4),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  song.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                                Text(
                                  song.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (onPlay != null)
                            Icon(Icons.play_circle_outline, color: scheme.primary),
                        ],
                      ),
                    ),
                  if (event.images.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          for (final url in event.images.take(3))
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: CoverArt(url: url, size: 56, radius: 4),
                            ),
                        ],
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

String _relativeTime(BigInt timeMs) {
  if (timeMs <= BigInt.zero) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(timeMs.toInt());
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}
