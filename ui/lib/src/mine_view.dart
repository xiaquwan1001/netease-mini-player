import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'cover_row.dart';
import 'digital_album_page.dart';
import 'messages_page.dart';
import 'my_collections_page.dart';
import 'net_retry.dart';
import 'profile_header.dart';
import 'ranking_view.dart';
import 'rust/api.dart' as rust;
import 'error_views.dart' show InlineError;
import 'song_actions.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'state_views.dart';
import 'toast.dart' show showToast;

/// "我的": 个人资料卡 / 我喜欢 / 收藏歌单 / 收藏播客 / 最近听过 / 听歌排行.
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
    required this.onOpenAlbum,
    required this.onOpenRecent,
    required this.onOpenFollows,
    required this.onOpenFolloweds,
    required this.onOpenLiked,
    this.onOpenMessages,
    this.onOpenMedals,
    this.onOpenVip,
    this.loadMessageCounts,
    this.onPlayLiked,
    this.loadLiked,
    this.loadPlaylists,
    this.loadPodcasts,
    this.loadProfile,
    this.loadRecent,
    this.loadRanking,
    this.loadAlbums,
  });

  final bool loggedIn;
  final VoidCallback onLogin;
  final VoidCallback onOpenAccounts;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;
  final void Function(rust.PodcastRadio radio) onOpenPodcast;
  final void Function(rust.AlbumItem album) onOpenAlbum;
  final VoidCallback onOpenRecent;

  /// 资料卡上的"关注 N" / "粉丝 N"
  /// 返回 Future: 列表页 pop 后资料卡要重拉一次, 让关注/取关后的数字立即更新。
  final Future<void> Function() onOpenFollows;
  final Future<void> Function() onOpenFolloweds;

  /// 打开"我喜欢的音乐"详情页
  final VoidCallback onOpenLiked;

  /// 打开消息中心(不传就不显示入口)
  final VoidCallback? onOpenMessages;

  /// 等级/勋章墙入口(未登录或未接线时不显示)
  final VoidCallback? onOpenMedals;

  /// 黑胶会员入口(审查 P1-7.9: 会员是账号资产, 从设置搬到「我的」;
  /// 不传则不显示该行)
  final VoidCallback? onOpenVip;

  /// 未读计数(缺省走 rust.messageCounts)
  final MessageCountsLoader? loadMessageCounts;

  /// 点播"我喜欢的音乐"里的曲目(与 onPlaySongs 的区别: 队列来源可以标成
  /// "我喜欢的音乐"这个歌单 id, 详情页的"定位正在播放"才有依据)。缺省回落 onPlaySongs。
  final void Function(List<rust.SongDto> songs, int index)? onPlayLiked;

  final Future<List<rust.SongDto>> Function()? loadLiked;
  final Future<List<rust.Playlist>> Function()? loadPlaylists;
  final Future<List<rust.PodcastRadio>> Function()? loadPodcasts;
  final Future<rust.ProfileDetail> Function()? loadProfile;
  final Future<List<rust.SongDto>> Function()? loadRecent;

  /// 听歌排行("all" 总量 / "week" 当周). 缺省走 rust.playRanking.
  final RankingLoader? loadRanking;

  /// 收藏的专辑(需登录). 缺省走 rust.subscribedAlbums.
  final Future<List<rust.AlbumItem>> Function()? loadAlbums;

  @override
  State<MineView> createState() => _MineViewState();
}

class _MineViewState extends State<MineView> {
  /// 下拉刷新代际: 变一次就让各区块换 key 重挂载(= 真正重拉数据)。
  /// 区块本身开了 keepAlive, 不换 key 的话 setState 只会复用旧数据。
  int _dataGeneration = 0;

  Future<List<rust.SongDto>> Function() get _liked =>
      widget.loadLiked ?? rust.likedSongs;
  Future<List<rust.Playlist>> Function() get _playlists =>
      widget.loadPlaylists ?? rust.myPlaylists;
  Future<List<rust.PodcastRadio>> Function() get _podcasts =>
      widget.loadPodcasts ?? (() => rust.subscribedPodcasts(limit: 50));
  Future<List<rust.AlbumItem>> Function() get _albums =>
      widget.loadAlbums ?? (() => rust.subscribedAlbums(limit: 50));

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
              Icon(
                Icons.account_circle,
                size: 56,
                color: Theme.of(context).colorScheme.outline,
              ),
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
      onRefresh: () async => setState(() => _dataGeneration += 1),
      // 账户页整页被用户点名"左右空隙大": 页面 12 + ListTile 默认 16 = 28dp。
      // 列表行统一收到 12(叠后 24), 歌曲行仍走 SongTile 的 kSongRowPadding。
      child: ListTileTheme(
        data: const ListTileThemeData(
          contentPadding: EdgeInsets.symmetric(horizontal: 12),
        ),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            _ProfileSection(
              key: ValueKey('mine-profile-$_dataGeneration'),
              loggedIn: widget.loggedIn,
              onOpenAccounts: widget.onOpenAccounts,
              onLogin: widget.onLogin,
              load: widget.loadProfile,
              onOpenFollows: widget.onOpenFollows,
              onOpenFolloweds: widget.onOpenFolloweds,
            ),
            if (widget.onOpenMessages != null) ...[
              const SizedBox(height: 4),
              MessageEntryCard(
                onOpen: widget.onOpenMessages!,
                load: widget.loadMessageCounts,
              ),
            ],
            if (widget.onOpenVip != null) ...[
              const SizedBox(height: 4),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.workspace_premium_outlined),
                  title: const Text('黑胶会员'),
                  subtitle: const Text('签到 / 任务 / 成长值(只读)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onOpenVip,
                ),
              ),
            ],
            if (widget.loggedIn) ...[
              const SizedBox(height: 4),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.album_outlined),
                  title: const Text('数字专辑(只读)'),
                  subtitle: const Text('已购专辑 / 已购单曲 / 详情销量'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const DigitalAlbumPage(),
                    ),
                  ),
                ),
              ),
            ],
            if (widget.loggedIn && widget.onOpenMedals != null) ...[
              const SizedBox(height: 4),
              Card(
                margin: EdgeInsets.zero,
                child: ListTile(
                  leading: const Icon(Icons.military_tech_outlined),
                  title: const Text('等级与勋章'),
                  subtitle: const Text('等级进度 / 勋章墙(只读)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: widget.onOpenMedals,
                ),
              ),
            ],
            const SizedBox(height: 4),
            const SigninCard(),
            const SizedBox(height: 4),
            _LikedSection(
              key: ValueKey('mine-liked-$_dataGeneration'),
              load: _liked,
              onPlay: widget.onPlayLiked ?? widget.onPlaySongs,
              onOpenAll: widget.onOpenLiked,
            ),
            const SizedBox(height: 16),
            _PlaylistsSection(
              key: ValueKey('mine-playlists-$_dataGeneration'),
              load: _playlists,
              onOpen: widget.onOpenPlaylist,
              onOpenAll: () => showMyPlaylistsPage(
                context,
                load: _playlists,
                onOpen: widget.onOpenPlaylist,
              ),
            ),
            const SizedBox(height: 16),
            _PodcastsSection(
              key: ValueKey('mine-podcasts-$_dataGeneration'),
              load: _podcasts,
              onOpen: widget.onOpenPodcast,
              onOpenAll: () => showMyPodcastsPage(
                context,
                load: _podcasts,
                onOpen: widget.onOpenPodcast,
              ),
            ),
            const SizedBox(height: 16),
            _AlbumsSection(
              key: ValueKey('mine-albums-$_dataGeneration'),
              load: _albums,
              onOpen: widget.onOpenAlbum,
              onOpenAll: () => showMyAlbumsPage(
                context,
                load: _albums,
                onOpen: widget.onOpenAlbum,
              ),
            ),
            const SizedBox(height: 16),
            _RecentSection(
              key: ValueKey('mine-recent-$_dataGeneration'),
              load: _loadRecent,
              onOpenAll: widget.onOpenRecent,
              onPlay: widget.onPlaySongs,
            ),
            const SizedBox(height: 16),
            _RankingSection(
              key: ValueKey('mine-ranking-$_dataGeneration'),
              load: widget.loadRanking,
              onPlay: widget.onPlaySongs,
              onOpenAll: () => showPlayRanking(
                context,
                onPlaySongs: widget.onPlaySongs,
                load: widget.loadRanking,
              ),
            ),
          ],
        ),
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
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          ?trailing,
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
  final Widget Function(BuildContext context, T data, VoidCallback reload)
  builder;
  final String emptyText;

  @override
  State<_AsyncSection<T>> createState() => _AsyncSectionState<T>();
}

class _AsyncSectionState<T> extends State<_AsyncSection<T>>
    with AutomaticKeepAliveClientMixin<_AsyncSection<T>> {
  late Future<T> _future;

  // 用户反馈: 区块一移出视野就被 ListView 回收, 回来时重新转圈 -> 我的页上下抽搐。
  // 保持存活后数据/高度都不再重置(下拉刷新仍通过 key 换代重拉)。
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = retryNetwork(widget.load);
  }

  void _reload() => setState(() => _future = retryNetwork(widget.load));

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<T>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const LoadingView(
            size: 22,
            padding: EdgeInsets.symmetric(vertical: 20),
          );
        }
        if (snap.hasError) {
          return InlineError(
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

// ---------------- 个人资料卡(背景图/头像) ----------------

class _ProfileSection extends StatefulWidget {
  const _ProfileSection({
    super.key,
    required this.loggedIn,
    required this.onOpenAccounts,
    required this.onLogin,
    required this.onOpenFollows,
    required this.onOpenFolloweds,
    this.load,
  });

  final bool loggedIn;
  final VoidCallback onOpenAccounts;
  final VoidCallback onLogin;
  final Future<void> Function() onOpenFollows;
  final Future<void> Function() onOpenFolloweds;
  final Future<rust.ProfileDetail> Function()? load;

  @override
  State<_ProfileSection> createState() => _ProfileSectionState();
}

class _ProfileSectionState extends State<_ProfileSection>
    with AutomaticKeepAliveClientMixin<_ProfileSection> {
  rust.ProfileDetail? _detail;

  @override
  bool get wantKeepAlive => true;

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

  /// 关注/粉丝列表页里可能关注/取关了, 返回后重拉资料卡让数字立即更新。
  Future<void> _openFollowList(Future<void> Function() open) async {
    await open();
    if (!mounted || !widget.loggedIn) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ProfileHeader(
      detail: _detail,
      fallbackNickname: widget.loggedIn ? '我的账号' : null,
      loggedIn: widget.loggedIn,
      onTap: widget.loggedIn ? widget.onOpenAccounts : widget.onLogin,
      onTapFollows: widget.loggedIn
          ? () => _openFollowList(widget.onOpenFollows)
          : null,
      onTapFolloweds: widget.loggedIn
          ? () => _openFollowList(widget.onOpenFolloweds)
          : null,
    );
  }
}

// ---------------- 我喜欢 ----------------

class _LikedSection extends StatelessWidget {
  const _LikedSection({
    super.key,
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
            final playable = [
              for (final s in songs)
                if (s.playable) s,
            ];
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
                      // 与同页带图标入口行同一栅格(12), 文字不再左右跳
                      contentPadding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
                      leading: CoverArt(
                        url: preview[i].coverUrl,
                        size: 40,
                        radius: 4,
                      ),
                      title: SongTitleWithBadges(song: preview[i]),
                      subtitle: Text(
                        preview[i].artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (songs.length > preview.length &&
                              i == preview.length - 1)
                            Text(
                              '共 ${songs.length} 首',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          SongOverflowButton(
                            song: preview[i],
                            size: 20,
                            source: SongActionSource.playlist,
                          ),
                        ],
                      ),
                      onTap: preview[i].playable
                          ? () {
                              final index = playable.indexWhere(
                                (s) => s.id == preview[i].id,
                              );
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
  const _PlaylistsSection({
    super.key,
    required this.load,
    required this.onOpen,
    required this.onOpenAll,
  });

  final Future<List<rust.Playlist>> Function() load;
  final void Function(rust.Playlist playlist) onOpen;

  /// 二级整页("查看全部")
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '收藏的歌单',
          trailing: TextButton(onPressed: onOpenAll, child: const Text('查看全部')),
        ),
        _AsyncSection<List<rust.Playlist>>(
          load: load,
          emptyText: '还没有收藏歌单',
          builder: (context, lists, reload) => SizedBox(
            height: kCoverCardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: lists.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final pl = lists[i];
                return SizedBox(
                  width: 118,
                  child: CoverCard(
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
  const _PodcastsSection({
    super.key,
    required this.load,
    required this.onOpen,
    required this.onOpenAll,
  });

  final Future<List<rust.PodcastRadio>> Function() load;
  final void Function(rust.PodcastRadio radio) onOpen;

  /// 二级整页("查看全部")
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '收藏的播客',
          trailing: TextButton(onPressed: onOpenAll, child: const Text('查看全部')),
        ),
        _AsyncSection<List<rust.PodcastRadio>>(
          load: load,
          emptyText: '还没有收藏播客',
          builder: (context, radios, reload) => SizedBox(
            height: kCoverCardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: radios.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final r = radios[i];
                return SizedBox(
                  width: 118,
                  child: CoverCard(
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

// ---------------- 收藏的专辑 ----------------

class _AlbumsSection extends StatelessWidget {
  const _AlbumsSection({
    super.key,
    required this.load,
    required this.onOpen,
    required this.onOpenAll,
  });

  final Future<List<rust.AlbumItem>> Function() load;
  final void Function(rust.AlbumItem album) onOpen;

  /// 二级整页("查看全部")
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '收藏的专辑',
          trailing: TextButton(onPressed: onOpenAll, child: const Text('查看全部')),
        ),
        _AsyncSection<List<rust.AlbumItem>>(
          load: load,
          emptyText: '还没有收藏专辑(在专辑页点收藏)',
          builder: (context, albums, reload) => SizedBox(
            height: kCoverCardHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: albums.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final a = albums[i];
                return SizedBox(
                  width: 118,
                  child: CoverCard(
                    coverUrl: a.coverUrl,
                    title: a.name,
                    subtitle: [
                      if (a.artist.isNotEmpty) a.artist,
                      if (a.trackCount > BigInt.zero) '${a.trackCount} 首',
                    ].join(' · '),
                    onTap: () => onOpen(a),
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

// ---------------- 听歌排行 ----------------

/// "我的"页下方的听歌排行: 总排行/当周切换 + 前 5 条 + 查看全部.
class _RankingSection extends StatelessWidget {
  const _RankingSection({
    super.key,
    required this.load,
    required this.onPlay,
    required this.onOpenAll,
  });

  final RankingLoader? load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final VoidCallback onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '听歌排行'),
        PlayRankingView(
          load: load,
          onPlaySongs: onPlay,
          compact: true,
          onOpenAll: onOpenAll,
        ),
      ],
    );
  }
}

// ---------------- 最近听过 ----------------

class _RecentSection extends StatelessWidget {
  const _RecentSection({
    super.key,
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
                      // 与同页带图标入口行同一栅格(12), 文字不再左右跳
                      contentPadding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
                      leading: CoverArt(
                        url: preview[i].coverUrl,
                        size: 40,
                        radius: 4,
                      ),
                      title: SongTitleWithBadges(song: preview[i]),
                      subtitle: Text(
                        preview[i].artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: SongOverflowButton(
                        song: preview[i],
                        size: 20,
                        source: SongActionSource.playlist,
                      ),
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

// ---------------- 消息中心入口 ----------------

/// "我的"页的消息入口: 未读数合计 + 分项摘要。
/// 载入失败(未登录/网络)时退化成只有标题, 不报错。
class MessageEntryCard extends StatefulWidget {
  const MessageEntryCard({super.key, required this.onOpen, this.load});

  final VoidCallback onOpen;
  final MessageCountsLoader? load;

  @override
  State<MessageEntryCard> createState() => _MessageEntryCardState();
}

class _MessageEntryCardState extends State<MessageEntryCard>
    with AutomaticKeepAliveClientMixin<MessageEntryCard> {
  rust.MessageCountsDto? _counts;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final counts = await retryNetwork(widget.load ?? rust.messageCounts);
      if (!mounted) return;
      setState(() => _counts = counts);
    } catch (_) {
      // 静默: 入口仍可点开, 页内各自报错
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final counts = _counts;
    final theme = Theme.of(context);
    final detail = counts == null
        ? '私信 / 通知 / 评论'
        : [
            if (counts.private > 0) '私信 ${counts.private}',
            if (counts.notices > 0) '通知 ${counts.notices}',
            if (counts.comments > 0) '评论 ${counts.comments}',
          ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        leading: Badge(
          isLabelVisible: (counts?.total ?? 0) > 0,
          label: Text('${counts?.total ?? 0}'),
          child: const Icon(Icons.forum_outlined),
        ),
        title: const Text('消息中心'),
        subtitle: Text(
          detail.isEmpty ? '暂无未读' : detail,
          style: theme.textTheme.bodySmall,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: widget.onOpen,
      ),
    );
  }
}

// ---------------- 每日签到(云贝) ----------------

/// 签到卡片: 今日状态 + 累计/连续/本周天数.
/// 载入失败(未登录/网络)就整块不显示 —— 它是锦上添花, 不该在"我的"顶部占一行报错.
/// load/sign 可注入(测试用), 默认走 Rust 接口.
class SigninCard extends StatefulWidget {
  const SigninCard({super.key, this.load, this.sign});

  final Future<rust.SigninStatus> Function()? load;
  final Future<rust.SigninStatus> Function()? sign;

  @override
  State<SigninCard> createState() => _SigninCardState();
}

class _SigninCardState extends State<SigninCard>
    with AutomaticKeepAliveClientMixin<SigninCard> {
  rust.SigninStatus? _status;

  @override
  bool get wantKeepAlive => true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final status = await retryNetwork(widget.load ?? rust.signinStatus);
      if (!mounted) return;
      setState(() => _status = status);
    } catch (_) {
      // 未登录/网络失败: 不显示这块
    }
  }

  Future<void> _sign() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final before = _status;
      final status = await (widget.sign ?? rust.signIn)();
      if (!mounted) return;
      setState(() => _status = status);
      final earned = status.todayPoint;
      final already = before?.signedToday == true;
      showToast(
        context,
        already || earned == 0
            ? '今天已经签过了(累计 ${status.totalDays} 天)'
            : '签到成功, 云贝 +$earned(累计 ${status.totalDays} 天)',
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, '签到失败: ${friendlyError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final status = _status;
    if (status == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final detail = [
      '累计 ${status.totalDays} 天',
      '连续 ${status.continuousDays} 天',
      '本周 ${status.weekDays} 天',
    ].join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        leading: Icon(
          status.signedToday ? Icons.task_alt : Icons.calendar_month_outlined,
          color: status.signedToday ? theme.colorScheme.primary : null,
        ),
        title: Text(status.signedToday ? '今日已签到' : '今天还没签到'),
        subtitle: Text(detail, style: theme.textTheme.bodySmall),
        trailing: status.signedToday
            ? Text('已签', style: TextStyle(color: theme.colorScheme.outline))
            : FilledButton.tonal(
                onPressed: _busy ? null : _sign,
                child: _busy
                    ? const LoadingView.inline(size: 16)
                    : const Text('签到'),
              ),
      ),
    );
  }
}
