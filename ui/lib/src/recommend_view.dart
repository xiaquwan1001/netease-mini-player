import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'cover_art.dart';
import 'cover_row.dart';
import 'layout.dart' show kSongRowPadding;
import 'net_retry.dart';
import 'playlist_square_page.dart';
import 'radio_explore_page.dart';
import 'rust/api.dart' as rust;
import 'toast.dart' show showToast;
import 'song_actions.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'style_page.dart';

/// 推荐页: 系统推荐的乐曲风格 + 每日推荐(歌曲/歌单) + 推荐播客 + 私人 FM + 心动模式.
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
    this.loadDailySongs,
    this.loadDailyPlaylists,
    this.loadPodcasts,
    this.loadFm,
    this.loadStyles,
    this.loadNewSongs,
    this.loadNewAlbums,
    this.onOpenAlbum,
    this.onPlayFm,
    this.onOpenNewRelease,
  });

  final bool loggedIn;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;
  final void Function(rust.PodcastRadio radio) onOpenPodcast;
  final VoidCallback onHeartMode;
  final VoidCallback onOpenDaily;

  final Future<List<rust.SongDto>> Function()? loadDailySongs;
  final Future<List<rust.Playlist>> Function()? loadDailyPlaylists;
  final Future<List<rust.PodcastRadio>> Function()? loadPodcasts;
  final Future<List<rust.SongDto>> Function()? loadFm;

  /// 系统推荐的曲风(我的曲风偏好; 未登录时后端退化成通用曲风表)
  final Future<List<rust.StyleTag>> Function()? loadStyles;

  /// 新歌速递 / 新碟上架
  final Future<List<rust.SongDto>> Function()? loadNewSongs;
  final Future<List<rust.AlbumItem>> Function()? loadNewAlbums;

  /// 点专辑卡片(不传就不显示"新碟上架")
  final void Function(rust.AlbumItem album)? onOpenAlbum;

  /// 私人FM 起播(不传就回落到 onPlaySongs)。上层用它标记"当前队列来自 FM",
  /// 以便歌曲菜单里的"不感兴趣"走 fm_trash 而不是日推 dislike。
  final void Function(List<rust.SongDto> songs, int index)? onPlayFm;

  /// 打开"新歌 / 新碟 / 歌手"分类页(不传就不显示"全部"入口)
  final VoidCallback? onOpenNewRelease;

  @override
  State<RecommendView> createState() => _RecommendViewState();
}

/// 页面横向留白 0 之后, 非歌曲类区块自己补回的 12dp。
Widget _hPad(Widget child) =>
    Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: child);

class _RecommendViewState extends State<RecommendView> {
  Future<List<rust.SongDto>> Function() get _dailySongs =>
      widget.loadDailySongs ?? rust.dailyRecommendSongs;
  Future<List<rust.Playlist>> Function() get _dailyPlaylists =>
      widget.loadDailyPlaylists ?? rust.dailyRecommendPlaylists;
  Future<List<rust.PodcastRadio>> Function() get _podcasts =>
      widget.loadPodcasts ?? (() => rust.podcastHot(limit: 10));
  Future<List<rust.SongDto>> Function() get _fm =>
      widget.loadFm ?? (() => rust.personalFm(limit: 30));
  Future<List<rust.StyleTag>> Function() get _styles =>
      widget.loadStyles ?? rust.stylePreference;
  Future<List<rust.SongDto>> Function() get _newSongs =>
      widget.loadNewSongs ?? (() => rust.newSongs(limit: 20));
  Future<List<rust.AlbumItem>> Function() get _newAlbums =>
      widget.loadNewAlbums ?? (() => rust.newAlbums(limit: 20, offset: 0));

  @override
  Widget build(BuildContext context) {
    // 卡片排列(一排/两排)是用户设置, 改了要立刻反映到已渲染的区块
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) => _buildBody(),
    );
  }

  Widget _buildBody() {
    return RefreshIndicator(
      onRefresh: () async => setState(() {}),
      // 2026-11 用户反馈: 推荐页歌曲行左右仍有空隙。页面横向留白改为 0,
      // 歌曲卡片直接铺满屏宽(行内只留 kSongRowPadding); 其它区块各自补 12dp。
      child: ListView(
        padding: const EdgeInsets.only(top: 8, bottom: 24),
        // 审查 P1-7.8 / §5.5: 首屏平级模块 8 个 + 1 个游离按钮 → 5 个。
        //  - 每日推荐歌曲 + 每日推荐歌单      → 合并为「每日推荐」(歌单在落地页第二个 tab)
        //  - 新歌速递 + 新碟上架              → 合并为「新歌新碟」(同一个「全部」)
        //  - 风格推荐                        → 排行榜区块内一行配图窗格(不再独占区块)
        //  - 歌单广场(游离按钮)              → 提升为「推荐歌单」标题右侧的「全部」
        //  - 推荐播客                        → 保留, 降到最底(第 2 屏)
        // 每个模块的落地页/回调都保持原样, 可达性零损失(见 test/ui_batch_c_ia_test.dart)。
        children: [
          _hPad(
            _QuickActions(
              onOpenDaily: widget.onOpenDaily,
              onPlayFm: _playFm,
              onHeartMode: widget.onHeartMode,
            ),
          ),
          const SizedBox(height: 16),
          _DailySongsSection(
            load: _dailySongs,
            onPlay: widget.onPlaySongs,
            onOpenAll: widget.onOpenDaily,
          ),
          const SizedBox(height: 16),
          // 排行榜(含「全部榜单」)已按用户要求移到搜索页;
          // 风格推荐留在推荐页, 现在是排行榜搬走后的独立单元。
          _hPad(
            _StylesSection(
              load: _styles,
              onPlaySongs: widget.onPlaySongs,
              onOpenPlaylist: widget.onOpenPlaylist,
            ),
          ),
          const SizedBox(height: 16),
          _hPad(
            _DailyPlaylistsSection(
              load: _dailyPlaylists,
              loggedIn: widget.loggedIn,
              onOpen: widget.onOpenPlaylist,
              onOpenAll: () => showPlaylistSquare(
                context,
                onOpenPlaylist: widget.onOpenPlaylist,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _NewReleaseSection(
            loadSongs: _newSongs,
            loadAlbums: widget.onOpenAlbum == null ? null : _newAlbums,
            loggedIn: widget.loggedIn,
            onPlay: widget.onPlaySongs,
            onOpenAlbum: widget.onOpenAlbum,
            onMore: widget.onOpenNewRelease,
          ),
          const SizedBox(height: 16),
          _hPad(
            _PodcastSection(
              load: _podcasts,
              loggedIn: widget.loggedIn,
              onOpen: widget.onOpenPodcast,
              onPlaySongs: widget.onPlaySongs,
            ),
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
      final start = widget.onPlayFm;
      if (start != null) {
        start(playable, 0);
      } else {
        widget.onPlaySongs(playable, 0);
      }
    } catch (e) {
      _snack(friendlyError(e));
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    showToast(context, message);
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

/// 独立加载的区块: loading / error / empty 都不影响兄弟区块
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
    required this.onPlayFm,
    required this.onHeartMode,
  });

  final VoidCallback onOpenDaily;
  final VoidCallback onPlayFm;
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
          child: _ActionCard(icon: Icons.radio, label: '私人FM', onTap: onPlayFm),
        ),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.onTap,
  });

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

// ---------------- 新歌速递 / 新碟上架 ----------------

/// 新歌速递: 一排歌曲(点任意一首按这个列表起播)
class _NewSongsSection extends StatelessWidget {
  const _NewSongsSection({required this.load, required this.onPlay});

  final Future<List<rust.SongDto>> Function() load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 「全部」入口由外层 _NewReleaseSection 统一提供(合并后全屏只有一个)
        _hPad(const _Caption('新歌速递')),
        _AsyncSection<List<rust.SongDto>>(
          load: load,
          emptyText: '暂时没有新歌',
          builder: (context, songs, reload) {
            final playable = [
              for (final s in songs)
                if (s.playable) s,
            ];
            final preview = songs.take(6).toList();
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in preview)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding: kSongRowPadding,
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
                      trailing: SongOverflowButton(song: s, size: 20),
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
        ),
      ],
    );
  }
}

/// 新碟上架: 横向封面卡片
class _NewAlbumsSection extends StatelessWidget {
  const _NewAlbumsSection({
    required this.load,
    required this.onOpen,
    required this.loggedIn,
  });

  final Future<List<rust.AlbumItem>> Function() load;
  final void Function(rust.AlbumItem album) onOpen;
  final bool loggedIn;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 「全部」入口由外层 _NewReleaseSection 统一提供(合并后全屏只有一个)
        const _Caption('新碟上架'),
        _AsyncSection<List<rust.AlbumItem>>(
          load: load,
          emptyText: loggedIn ? '暂时没有新碟' : '暂时没有新碟',
          builder: (context, albums, reload) => CoverRow(
            height: 176,
            rows: AppSettings.instance.coverRows,
            children: [
              for (final a in albums)
                CoverCard(
                  coverUrl: a.coverUrl,
                  title: a.name,
                  subtitle: [
                    if (a.artist.isNotEmpty) a.artist,
                    if (a.trackCount > BigInt.zero) '${a.trackCount} 首',
                  ].join(' · '),
                  onTap: () => onOpen(a),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 小标题: 合并区块内部的次级分类名(不是平级区块, 没有自己的「全部」出口)。
class _Caption extends StatelessWidget {
  const _Caption(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 2),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

/// 新歌新碟: 新歌速递 + 新碟上架 合并成一格(审查 §5.5: 两者原本各自有一个
/// 「全部」且都指向同一个 NewReleasePage, 重复入口让人以为内容不同)。
/// 一个标题 + 一个「全部」, 内部用两个小标题区分; 两个列表仍各自独立加载。
class _NewReleaseSection extends StatelessWidget {
  const _NewReleaseSection({
    required this.loadSongs,
    required this.loadAlbums,
    required this.loggedIn,
    required this.onPlay,
    this.onOpenAlbum,
    this.onMore,
  });

  final Future<List<rust.SongDto>> Function() loadSongs;

  /// 为 null 表示不显示新碟(上层没给 onOpenAlbum)
  final Future<List<rust.AlbumItem>> Function()? loadAlbums;
  final bool loggedIn;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final void Function(rust.AlbumItem album)? onOpenAlbum;

  /// "全部"入口(新歌/新碟/歌手分类页)
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final albums = loadAlbums;
    final open = onOpenAlbum;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hPad(
          _SectionHeader(
            title: '新歌新碟',
            trailing: onMore == null
                ? null
                : TextButton(onPressed: onMore, child: const Text('全部')),
          ),
        ),
        _NewSongsSection(load: loadSongs, onPlay: onPlay),
        if (albums != null && open != null) ...[
          const SizedBox(height: 10),
          _hPad(
            _NewAlbumsSection(load: albums, onOpen: open, loggedIn: loggedIn),
          ),
        ],
      ],
    );
  }
}

// ---------------- 风格推荐 ----------------

/// 风格推荐区块(排行榜搬到搜索页之后独立成块)。
class _StylesSection extends StatelessWidget {
  const _StylesSection({
    required this.load,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
  });

  final Future<List<rust.StyleTag>> Function() load;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: '风格推荐'),
        _StyleTiles(
          load: load,
          onPlaySongs: onPlaySongs,
          onOpenPlaylist: onOpenPlaylist,
        ),
      ],
    );
  }
}

// ---------------- 风格推荐(排行榜区块内的一行配图窗格) ----------------

/// 系统按听歌口味算出来的曲风(网易云"风格推荐").
/// 点一个风格进风格详情页: 该曲风下的歌单 + 歌曲.
///
/// 历史: 审查 §5.5 把它从平级区块压成一行纯文字 chips(只留关键词),
/// 配图只在点进详情页后才看得到; 现在把配图搬回推荐页 ——
/// 每个风格是一块「配图 + 名字」的窗格(与详情页头部的同一张图),
/// 仍然是排行榜下方的次级内容, 不新起平级区块。
class _StyleTiles extends StatelessWidget {
  const _StyleTiles({
    required this.load,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
  });

  final Future<List<rust.StyleTag>> Function() load;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;

  /// 窗格边长: 比歌单封面(118)小一档, 一行能看 3~4 个, 不把排行榜区块撑太高。
  static const double _tileSize = 88;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AsyncSection<List<rust.StyleTag>>(
          load: load,
          emptyText: '暂时没有风格推荐',
          // 横滑而不是 Wrap: 窗格高度(图 + 名字)本来就不固定, 交给 Row 自己撑,
          // 大字号下不会像定高列表那样溢出。
          builder: (context, tags, reload) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < tags.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  SizedBox(width: _tileSize, child: _tile(context, tags[i])),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 一块风格窗格: 配图(没有就退回钢琴图标占位) + 名字, 点开进风格详情。
  Widget _tile(BuildContext context, rust.StyleTag tag) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cover = tag.coverUrl;
    return InkWell(
      onTap: () => showStyleDetail(
        context,
        tag: tag,
        onPlaySongs: onPlaySongs,
        onOpenPlaylist: onOpenPlaylist,
      ),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (cover == null || cover.isEmpty)
            // 匿名/旧版本接口的 picUrl 是 yyimgs 相对路径(Rust 侧已丢掉),
            // 这时退回钢琴图标占位: 保证离线/图挂了也有同样大小的可点入口。
            Container(
              width: _tileSize,
              height: _tileSize,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.piano, size: 30, color: scheme.primary),
            )
          else
            CoverArt(url: cover, size: _tileSize, radius: 8),
          const SizedBox(height: 4),
          Text(
            tag.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        ],
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
        // 审查 §5.5: 「每日推荐歌曲」+「每日推荐歌单」合并成一格「每日推荐」,
        // 歌单落在落地页的第二个 tab; 同屏不再出现第二个「查看全部」。
        _hPad(
          _SectionHeader(
            title: '每日推荐',
            // 同一语义(看完整列表)全页统一叫「全部」, 放区块标题右侧(审查 P1-7.13)
            trailing: TextButton(onPressed: onOpenAll, child: const Text('全部')),
          ),
        ),
        _AsyncSection<List<rust.SongDto>>(
          load: load,
          emptyText: '今天没有推荐歌曲',
          builder: (context, songs, reload) {
            final playable = [
              for (final s in songs)
                if (s.playable) s,
            ];
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
                      contentPadding: kSongRowPadding,
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
                      trailing: preview[i].playable
                          // 行尾 "..." 菜单(下一首播放/收藏/分享/不感兴趣等)
                          ? SongOverflowButton(
                              song: preview[i],
                              size: 20,
                              source: SongActionSource.dailyRecommend,
                            )
                          : Text(
                              '无版权',
                              style: Theme.of(context).textTheme.labelSmall,
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

// ---------------- 推荐歌单 / 播客 ----------------

class _DailyPlaylistsSection extends StatelessWidget {
  const _DailyPlaylistsSection({
    required this.load,
    required this.loggedIn,
    required this.onOpen,
    this.onOpenAll,
  });

  final Future<List<rust.Playlist>> Function() load;
  final bool loggedIn;
  final void Function(rust.Playlist playlist) onOpen;

  /// 「全部」出口: 歌单广场(原先是区块下方一枚游离的「歌单广场」按钮,
  /// 审查 §5.5 要求提到标题右侧, 与其它区块一致)
  final VoidCallback? onOpenAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '推荐歌单',
          trailing: onOpenAll == null
              ? null
              : TextButton(onPressed: onOpenAll, child: const Text('全部')),
        ),
        _AsyncSection<List<rust.Playlist>>(
          load: load,
          emptyText: loggedIn ? '今天没有推荐歌单' : '登录后显示每日推荐歌单',
          builder: (context, lists, reload) => CoverRow(
            height: 176,
            rows: AppSettings.instance.coverRows,
            children: [
              for (final pl in lists)
                CoverCard(
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
    this.onPlaySongs,
  });

  final Future<List<rust.PodcastRadio>> Function() load;
  final bool loggedIn;
  final void Function(rust.PodcastRadio radio) onOpen;

  /// 电台广场节目榜点行直接播放(与上层播放回调同一签名)
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          title: '推荐播客',
          trailing: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => RadioExplorePage(
                  onOpenRadio: (ctx, radio) {
                    onOpen(radio);
                  },
                  onPlaySongs: onPlaySongs,
                ),
              ),
            ),
            child: const Text('全部'),
          ),
        ),
        _AsyncSection<List<rust.PodcastRadio>>(
          load: load,
          emptyText: '暂无推荐播客',
          builder: (context, radios, reload) => CoverRow(
            height: 176,
            rows: AppSettings.instance.coverRows,
            children: [
              for (final radio in radios)
                CoverCard(
                  coverUrl: radio.coverUrl,
                  title: radio.name,
                  subtitle: [
                    if (radio.djName.isNotEmpty) radio.djName,
                    if (radio.programCount > BigInt.zero)
                      '${radio.programCount} 集',
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

/// 歌单/播客卡片行. rows=1 是单行横向滑动, rows=2 拆成两行横滑
/// (每行仍横滑, 只是把内容对半分, 一屏能多看到一倍).
