import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'profile_header.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';

/// "我的": 个人资料卡 / 我喜欢 / 收藏歌单 / 收藏播客 / 最近听过.
/// 关注艺人 + 关注动态都在独立的"关注"底部 tab(艺人分类在那边横向展示)。
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
    required this.onOpenRecent,
    required this.onOpenLiked,
    this.onPlayLiked,
    this.loadLiked,
    this.loadPlaylists,
    this.loadPodcasts,
    this.loadProfile,
    this.loadRecent,
  });

  final bool loggedIn;
  final VoidCallback onLogin;
  final VoidCallback onOpenAccounts;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.PlaylistDto playlist) onOpenPlaylist;
  final void Function(rust.PodcastRadioDto radio) onOpenPodcast;
  final VoidCallback onOpenRecent;

  /// 打开"我喜欢的音乐"详情页
  final VoidCallback onOpenLiked;

  /// 点播"我喜欢的音乐"里的曲目(与 onPlaySongs 的区别: 队列来源可以标成
  /// "我喜欢的音乐"这个歌单 id, 详情页的"定位正在播放"才有依据)。缺省回落 onPlaySongs。
  final void Function(List<rust.SongDto> songs, int index)? onPlayLiked;

  final Future<List<rust.SongDto>> Function()? loadLiked;
  final Future<List<rust.PlaylistDto>> Function()? loadPlaylists;
  final Future<List<rust.PodcastRadioDto>> Function()? loadPodcasts;
  final Future<rust.ProfileDetailDto> Function()? loadProfile;
  final Future<List<rust.SongDto>> Function()? loadRecent;

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
  /// 播放历史: 云端拉不到(未登录/网络差)时回落到本地播放记录
  Future<List<rust.SongDto>> _loadRecent() async {
    try {
      return await retryNetwork(
        widget.loadRecent ?? (() => rust.recentSongs(limit: 20)),
      );
    } catch (_) {
      return rust.localRecentSongs(limit: 20);
    }
  }

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
              const Text('登录后查看我喜欢的音乐、收藏歌单/播客和关注艺人'),
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
          _ProfileSection(
            loggedIn: widget.loggedIn,
            onOpenAccounts: widget.onOpenAccounts,
            onLogin: widget.onLogin,
            load: widget.loadProfile,
          ),
          const SizedBox(height: 4),
          _LikedSection(
            load: _liked,
            onPlay: widget.onPlayLiked ?? widget.onPlaySongs,
            onOpenAll: widget.onOpenLiked,
          ),
          const SizedBox(height: 16),
          _PlaylistsSection(load: _playlists, onOpen: widget.onOpenPlaylist),
          const SizedBox(height: 16),
          _PodcastsSection(load: _podcasts, onOpen: widget.onOpenPodcast),
          const SizedBox(height: 16),
          _RecentSection(
            load: _loadRecent,
            onOpenAll: widget.onOpenRecent,
            onPlay: widget.onPlaySongs,
          ),
        ],
      ),
    );
  }
}

// ---------------- 区块骨架 ----------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (trailing != null) trailing!,
        ],
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

// ---------------- 个人资料卡(背景图/头像) ----------------

class _ProfileSection extends StatefulWidget {
  const _ProfileSection({
    required this.loggedIn,
    required this.onOpenAccounts,
    required this.onLogin,
    this.load,
  });

  final bool loggedIn;
  final VoidCallback onOpenAccounts;
  final VoidCallback onLogin;
  final Future<rust.ProfileDetailDto> Function()? load;

  @override
  State<_ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends State<_ProfileSection> {
  rust.ProfileDetailDto? _detail;

  @override
  void initState() {
    super.initState();
    if (widget.loggedIn) _load();
  }

  @override
  void didUpdateWidget(covariant _ProfileSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loggedIn && !oldWidget.loggedIn) _load();
    if (!widget.loggedIn && _detail != null) {
      _detail = null;
    }
  }

  Future<void> _load() async {
    try {
      final detail = await retryNetwork(widget.load ?? rust.profileDetail);
      if (!mounted) return;
      setState(() => _detail = detail);
    } catch (_) {
      // 资料卡是锦上添花: 失败只保留默认背景/昵称
    }
  }

  @override
  Widget build(BuildContext context) {
    return ProfileHeader(
      detail: _detail,
      fallbackNickname: widget.loggedIn ? '我的账号' : null,
      loggedIn: widget.loggedIn,
      onTap: widget.loggedIn ? widget.onOpenAccounts : widget.onLogin,
    );
  }
}

// ---------------- 我喜欢 ----------------

class _LikedSection extends StatelessWidget {
  const _LikedSection({
    required this.load,
    required this.onPlay,
    required this.onOpenAll,
  });

  final Future<List<rust.SongDto>> Function() load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '我喜欢的音乐',
          trailing: TextButton(onPressed: onOpenAll, child: const Text('查看全部')),
        ),
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
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (songs.length > preview.length && i == preview.length - 1)
                            Text('共 ${songs.length} 首',
                                style: Theme.of(context).textTheme.labelSmall),
                          SongOverflowButton(song: preview[i], size: 20),
                        ],
                      ),
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

// ---------------- 最近听过 ----------------

class _RecentSection extends StatelessWidget {
  const _RecentSection({
    required this.load,
    required this.onOpenAll,
    required this.onPlay,
  });

  final Future<List<rust.SongDto>> Function() load;
  final VoidCallback onOpenAll;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '最近听过',
          trailing: TextButton(onPressed: onOpenAll, child: const Text('查看全部')),
        ),
        _AsyncSection<List<rust.SongDto>>(
          load: load,
          emptyText: '还没有播放记录',
          builder: (context, songs, reload) {
            final preview = songs.take(5).toList();
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
                      trailing: SongOverflowButton(song: preview[i], size: 20),
                      onTap: () => onPlay(songs, i),
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
