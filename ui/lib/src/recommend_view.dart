import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 推荐页: 每日推荐(歌曲/歌单) + 推荐播客 + 每日私人 FM + 心动模式.
///
/// 所有数据源独立加载(某块失败不影响其它块), 登录态变化时由上层换 key 重建.
class RecommendView extends StatefulWidget {
  const RecommendView({
    super.key,
    required this.loggedIn,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
    required this.onOpenPodcast,
    required this.onHeartMode,
    required this.onOpenDaily,
    required this.onOpenRecent,
    this.loadDailySongs,
    this.loadDailyPlaylists,
    this.loadPodcasts,
    this.loadFm,
  });

  final bool loggedIn;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.PlaylistDto playlist) onOpenPlaylist;
  final void Function(rust.PodcastRadioDto radio) onOpenPodcast;
  final VoidCallback onHeartMode;
  final VoidCallback onOpenDaily;
  final VoidCallback onOpenRecent;

  final Future<List<rust.SongDto>> Function()? loadDailySongs;
  final Future<List<rust.PlaylistDto>> Function()? loadDailyPlaylists;
  final Future<List<rust.PodcastRadioDto>> Function()? loadPodcasts;
  final Future<List<rust.SongDto>> Function()? loadFm;

  @override
  State<RecommendView> createState() => _RecommendViewState();
}

class _RecommendViewState extends State<RecommendView> {
  Future<List<rust.SongDto>> Function() get _dailySongs =>
      widget.loadDailySongs ?? rust.dailyRecommendSongs;
  Future<List<rust.PlaylistDto>> Function() get _dailyPlaylists =>
      widget.loadDailyPlaylists ?? rust.dailyRecommendPlaylists;
  Future<List<rust.PodcastRadioDto>> Function() get _podcasts =>
      widget.loadPodcasts ?? (() => rust.podcastHot(limit: 10));
  Future<List<rust.SongDto>> Function() get _fm =>
      widget.loadFm ?? (() => rust.personalFm(limit: 30));

  int _fmLoading = 0;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          _QuickActions(
            onOpenDaily: widget.onOpenDaily,
            onOpenRecent: widget.onOpenRecent,
            onHeartMode: widget.onHeartMode,
          ),
          const SizedBox(height: 12),
          _DailySongsSection(
            load: _dailySongs,
            onPlay: widget.onPlaySongs,
            onOpenAll: widget.onOpenDaily,
          ),
          const SizedBox(height: 16),
          _DailyPlaylistsSection(
            load: _dailyPlaylists,
            loggedIn: widget.loggedIn,
            onOpen: widget.onOpenPlaylist,
          ),
          const SizedBox(height: 16),
          _PodcastSection(load: _podcasts, loggedIn: widget.loggedIn, onOpen: widget.onOpenPodcast),
          const SizedBox(height: 16),
          _FmSection(
            loggedIn: widget.loggedIn,
            loading: _fmLoading > 0,
            onPlay: _playFm,
          ),
          const SizedBox(height: 16),
          _HeartModeCard(
            loggedIn: widget.loggedIn,
            onTap: widget.onHeartMode,
          ),
        ],
      ),
    );
  }

  Future<void> _playFm() async {
    if (!widget.loggedIn) {
      _snack('私人 FM 需要先登录');
      return;
    }
    setState(() => _fmLoading += 1);
    try {
      final songs = await retryNetwork(_fm);
      final playable = [
        for (final s in songs)
          if (s.playable) s,
      ];
      if (playable.isEmpty) {
        _snack('暂时没有可播放的 FM 曲目');
        return;
      }
      widget.onPlaySongs(playable, 0);
    } catch (e) {
      _snack(friendlyError(e));
    } finally {
      if (mounted) setState(() => _fmLoading -= 1);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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

/// 独立加载的区块: loading / error / empty 都不影响兄弟区块
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
    _future = _load();
  }

  Future<T> _load() => retryNetwork(widget.load);

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
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
            padding: const EdgeInsets.symmetric(vertical: 12),
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.error, fontSize: 12),
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

// ---------------- 快捷入口 ----------------

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.onOpenDaily,
    required this.onOpenRecent,
    required this.onHeartMode,
  });

  final VoidCallback onOpenDaily;
  final VoidCallback onOpenRecent;
  final VoidCallback onHeartMode;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ActionCard(
            icon: Icons.auto_awesome,
            label: '每日推荐',
            onTap: onOpenDaily,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionCard(
            icon: Icons.bolt,
            label: '心动模式',
            onTap: onHeartMode,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ActionCard(
            icon: Icons.history,
            label: '最近听过',
            onTap: onOpenRecent,
          ),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: scheme.primary),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------- 每日推荐歌曲 ----------------

class _DailySongsSection extends StatelessWidget {
  const _DailySongsSection({
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
          title: '每日推荐歌曲',
          trailing: TextButton(onPressed: onOpenAll, child: const Text('查看全部')),
        ),
        _AsyncSection<List<rust.SongDto>>(
          load: load,
          emptyText: '今天没有推荐歌曲',
          builder: (context, songs, reload) {
            final playable = [for (final s in songs) if (s.playable) s];
            final preview = songs.take(6).toList();
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
                      trailing: preview[i].playable
                          ? null
                          : Text('无版权', style: Theme.of(context).textTheme.labelSmall),
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

// ---------------- 推荐歌单 / 播客 ----------------

class _DailyPlaylistsSection extends StatelessWidget {
  const _DailyPlaylistsSection({
    required this.load,
    required this.loggedIn,
    required this.onOpen,
  });

  final Future<List<rust.PlaylistDto>> Function() load;
  final bool loggedIn;
  final void Function(rust.PlaylistDto playlist) onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '推荐歌单'),
        _AsyncSection<List<rust.PlaylistDto>>(
          load: load,
          emptyText: loggedIn ? '今天没有推荐歌单' : '登录后显示每日推荐歌单',
          builder: (context, lists, reload) => _CoverRow(
            height: 176,
            children: [
              for (final pl in lists)
                _CoverCard(
                  coverUrl: pl.coverUrl,
                  title: pl.name,
                  subtitle: '${pl.trackCount} 首',
                  onTap: () => onOpen(pl),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PodcastSection extends StatelessWidget {
  const _PodcastSection({
    required this.load,
    required this.loggedIn,
    required this.onOpen,
  });

  final Future<List<rust.PodcastRadioDto>> Function() load;
  final bool loggedIn;
  final void Function(rust.PodcastRadioDto radio) onOpen;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '推荐播客'),
        _AsyncSection<List<rust.PodcastRadioDto>>(
          load: load,
          emptyText: '暂无推荐播客',
          builder: (context, radios, reload) => _CoverRow(
            height: 176,
            children: [
              for (final radio in radios)
                _CoverCard(
                  coverUrl: radio.coverUrl,
                  title: radio.name,
                  subtitle: [
                    if (radio.djName.isNotEmpty) radio.djName,
                    if (radio.programCount > BigInt.zero) '${radio.programCount} 集',
                  ].join(' · '),
                  onTap: () => onOpen(radio),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CoverRow extends StatelessWidget {
  const _CoverRow({required this.children, required this.height});

  final List<Widget> children;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => SizedBox(width: 118, child: children[i]),
      ),
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

// ---------------- 私人 FM / 心动模式 ----------------

class _FmSection extends StatelessWidget {
  const _FmSection({
    required this.loggedIn,
    required this.loading,
    required this.onPlay,
  });

  final bool loggedIn;
  final bool loading;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.primaryContainer,
          child: Icon(Icons.radio, color: scheme.onPrimaryContainer),
        ),
        title: const Text('每日私人 FM'),
        subtitle: Text(
          loggedIn ? '按你的口味连续推荐, 从第一首开始播放' : '登录后可用',
        ),
        trailing: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : FilledButton.tonal(
                onPressed: loggedIn ? onPlay : null,
                child: const Text('播放'),
              ),
      ),
    );
  }
}

class _HeartModeCard extends StatelessWidget {
  const _HeartModeCard({required this.loggedIn, required this.onTap});

  final bool loggedIn;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(Icons.auto_awesome, color: scheme.onSecondaryContainer),
        ),
        title: const Text('心动模式'),
        subtitle: Text(
          loggedIn ? '以当前播放的歌曲为种子, 连续推荐相似曲目' : '登录后推荐更准',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
