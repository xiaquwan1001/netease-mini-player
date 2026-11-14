import 'package:flutter/material.dart';

import 'category_bar.dart';
import 'cover_art.dart';
import 'format.dart' show formatCountMagnitude;
import 'layout.dart';
import 'library_view.dart';
import 'mv_page.dart' show showMvPage;
import 'rust/api.dart' as rust;
import 'song_tile.dart';
import 'user_nav.dart';

/// MV 分区条目(需求 10: 搜索结果与联想都要有 MV 分类)。
///
/// 契约与后端 lane 对齐 —— Rust 侧 `SearchBundleDto.mvs: List<MvItem>`,
/// 字段 `{id, name, coverUrl, artistName, playCount}`(cloudsearch type=1004)。
/// FFI 还没合入时由调用方传同构的 [SearchMv](main.dart 暂不传 ⇒ 分区为空,
/// 但 UI 的分组/图标/点击进播放页已经就位, 后端一接上就有内容)。
class SearchMv {
  const SearchMv({
    required this.id,
    required this.name,
    this.coverUrl,
    this.artistName = '',
    this.playCount,
  });

  final BigInt id;
  final String name;
  final String? coverUrl;
  final String artistName;

  /// 播放次数(Rust 侧 BigInt; 未知时 null)
  final BigInt? playCount;
}

/// 综合搜索结果: 单曲 / 艺人 / 专辑 / 歌单 / 播客 / 用户 / MV.
///
/// 分类**横向**排(可横滑的 ChoiceChip 条), 一次只渲染一个分类:
/// 之前五个分区纵向堆叠, 想找"艺人"要先划过整页单曲(用户反馈必须往下翻)。
/// 空分类不出现; 全部为空时居中提示。
///
/// 卡片型分区(艺人/专辑/歌单/播客/用户/MV)统一走 [CoverGrid]:
/// 每行正好 `AppSettings.gridColumns` 个, 格子宽均分可用宽度, 末行左对齐、
/// 右侧不再留一条固定空隙(需求 8/14)。
class SearchResultsView extends StatefulWidget {
  const SearchResultsView({
    super.key,
    required this.bundle,
    required this.liked,
    required this.currentTrackId,
    required this.onPlaySong,
    required this.onOpenArtist,
    required this.onOpenAlbum,
    required this.onOpenPlaylist,
    required this.onOpenPodcast,
    this.onOpenMv,
    this.mvs = const <SearchMv>[],
    this.onMenu,
  });

  final rust.SearchBundleDto bundle;
  final Set<BigInt> liked;
  final BigInt? currentTrackId;

  /// 点单曲: 用可见单曲列表重置队列后播放
  final void Function(rust.SongDto) onPlaySong;
  final void Function(rust.SearchArtist) onOpenArtist;
  final void Function(rust.SearchAlbum) onOpenAlbum;
  final void Function(rust.SearchPlaylistItem) onOpenPlaylist;
  final void Function(rust.SearchPodcast) onOpenPodcast;

  /// MV 分区数据(FFI 合入后由 main.dart 从 `bundle.mvs` 转过来)
  final List<SearchMv> mvs;

  /// 点 MV 卡片; 不传时默认打开 MV 播放页([showMvPage])
  final void Function(SearchMv mv)? onOpenMv;

  /// 行尾 "..." 菜单
  final void Function(rust.SongDto)? onMenu;

  @override
  State<SearchResultsView> createState() => _SearchResultsViewState();
}

/// 七个分类(顺序即 chip 顺序)
enum _Section { songs, artists, albums, playlists, podcasts, users, mvs }

extension on _Section {
  String get label => switch (this) {
    _Section.songs => '单曲',
    _Section.artists => '艺人',
    _Section.albums => '专辑',
    _Section.playlists => '歌单',
    _Section.podcasts => '播客',
    _Section.users => '用户',
    _Section.mvs => 'MV',
  };
}

class _SearchResultsViewState extends State<SearchResultsView> {
  /// 当前分类(null = 用第一个非空分类)
  _Section? _selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bundle = widget.bundle;
    final visible = visibleSongs(bundle.songs, widget.liked);
    final hidden = hiddenUnplayableCount(bundle.songs, widget.liked);

    // 分类条**始终显示全部 5 个分类**: 以前空分类直接隐藏 chip, 用户会以为
    // 「艺人/专辑分类被删了」或「被横向滚动裁掉看不见」(2026-11 反馈)。
    // 空分类点进去给明确提示, 而不是让分类自己消失。
    final available = _Section.values;
    if (!available.any((s) => _hasData(s, visible))) {
      return Center(
        child: Text(
          '没有找到相关内容',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    // 旧选择永远有效; 默认落在第一个有数据的分类上(通常是单曲)
    final selected =
        _selected ?? available.firstWhere((s) => _hasData(s, visible));

    return Column(
      children: [
        _sectionBar(context, available, selected),
        Expanded(child: _buildSection(context, selected, visible, hidden)),
      ],
    );
  }

  /// 分类条: 与输入联想共用 [CategoryBar](换行铺开, 不做横向滚动)。
  ///
  /// 横滑版在窄屏上把后两个分类藏在屏幕外, 用户/测试都当成「分类丢了」;
  /// 换行后 5 个 chip 一定全部看得见, 大字模式最多占两行。
  /// 对齐/宽度的几何坑统一在 [CategoryBar] 里解决(见那里的注释)。
  Widget _sectionBar(
    BuildContext context,
    List<_Section> available,
    _Section selected,
  ) {
    return CategoryBar(
      labels: [for (final s in available) s.label],
      selected: available.indexOf(selected),
      onSelected: (i) {
        final next = available[i];
        if (_selected != next) setState(() => _selected = next);
      },
    );
  }

  /// 该分类当前是否有数据(单曲看的是「可见单曲」, 与列表一致)
  bool _hasData(_Section section, List<rust.SongDto> visible) {
    final bundle = widget.bundle;
    return switch (section) {
      _Section.songs => visible.isNotEmpty,
      _Section.artists => bundle.artists.isNotEmpty,
      _Section.albums => bundle.albums.isNotEmpty,
      _Section.playlists => bundle.playlists.isNotEmpty,
      _Section.podcasts => bundle.podcasts.isNotEmpty,
      _Section.users => bundle.users.isNotEmpty,
      _Section.mvs => widget.mvs.isNotEmpty,
    };
  }

  /// 空分类的占位: 说清「分类在, 只是这次没结果」, 而不是静默隐藏。
  Widget _emptySectionHint(BuildContext context, _Section section) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '「${section.label}」没有匹配结果',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              '这一类仍然可用: 换更长/更准的关键词再搜一次',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(
    BuildContext context,
    _Section section,
    List<rust.SongDto> visible,
    int hidden,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final bundle = widget.bundle;
    if (!_hasData(section, visible)) {
      return _emptySectionHint(context, section);
    }
    switch (section) {
      case _Section.songs:
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // 单曲行要"左右占满": 不额外加水平留白, 提示行自己补
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  kPagePadding,
                  4,
                  kPagePadding,
                  4,
                ),
                child: Text(
                  '已隐藏 $hidden 首无版权曲目',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            for (final s in visible)
              SongTile(
                song: s,
                active: widget.currentTrackId == s.id,
                liked: widget.liked.contains(s.id),
                onTap: () => widget.onPlaySong(s),
                onMenu: widget.onMenu == null ? null : () => widget.onMenu!(s),
              ),
          ],
        );
      case _Section.artists:
        return _grid<rust.SearchArtist>(
          bundle.artists,
          (a, w) => _gridCard(
            context,
            tileWidth: w,
            onTap: () => widget.onOpenArtist(a),
            cover: _roundCover(a.avatarUrl, w),
            name: a.name,
            subtitle: a.alias.isNotEmpty ? a.alias : '${a.albumCount} 张专辑',
          ),
        );
      case _Section.albums:
        return _grid<rust.SearchAlbum>(
          bundle.albums,
          (al, w) => _gridCard(
            context,
            tileWidth: w,
            onTap: () => widget.onOpenAlbum(al),
            cover: CoverArt(url: al.coverUrl, size: w, radius: 8),
            name: al.name,
            subtitle: '${al.artist} · ${al.trackCount} 首',
          ),
        );
      case _Section.playlists:
        return _grid<rust.SearchPlaylistItem>(
          bundle.playlists,
          (p, w) => _gridCard(
            context,
            tileWidth: w,
            onTap: () => widget.onOpenPlaylist(p),
            cover: CoverArt(url: p.coverUrl, size: w, radius: 8),
            name: p.name,
            subtitle: '${p.creatorName} · ${p.trackCount} 首',
          ),
        );
      case _Section.podcasts:
        return _grid<rust.SearchPodcast>(
          bundle.podcasts,
          (p, w) => _gridCard(
            context,
            tileWidth: w,
            onTap: () => widget.onOpenPodcast(p),
            cover: CoverArt(url: p.coverUrl, size: w, radius: 8),
            name: p.name,
            subtitle: '${p.djName} · ${p.programCount} 集',
          ),
        );
      case _Section.users:
        // 用户(cloudsearch type=1002): 点卡片直接进个人主页, 走全局 UserNav
        // (与评论/动态同一个入口), 不再单独接一层回调。
        return _grid<rust.UserItem>(
          bundle.users,
          (u, w) => _gridCard(
            context,
            tileWidth: w,
            onTap: () => UserNav.open(context, u.id, nickname: u.name),
            cover: _roundCover(u.avatarUrl, w),
            name: u.name,
            subtitle: u.signature.isEmpty ? '@${u.id}' : u.signature,
          ),
        );
      case _Section.mvs:
        // MV(cloudsearch type=1004): 点卡片进 MV 播放页(与 MV 页同一入口)
        final open = widget.onOpenMv;
        return _grid<SearchMv>(
          widget.mvs,
          (mv, w) => _gridCard(
            context,
            tileWidth: w,
            onTap: () {
              if (open != null) {
                open(mv);
              } else {
                showMvPage(context, mvId: mv.id, name: mv.name);
              }
            },
            cover: _mvCover(mv.coverUrl, w),
            name: mv.name,
            subtitle: _mvSubtitle(mv),
          ),
        );
    }
  }

  /// 卡片型分区共用网格: 每行正好 [AppSettings.gridColumns] 个,
  /// 格子宽 = (可用宽度 - (n-1)×间距) / n, 末行左对齐、右侧无固定留白。
  Widget _grid<T>(
    List<T> items,
    Widget Function(T item, double tileWidth) builder,
  ) {
    return CoverGrid(
      itemCount: items.length,
      padding: kGridInsets,
      itemBuilder: (context, i, tileWidth) => builder(items[i], tileWidth),
    );
  }

  /// 圆形封面(艺人/用户): 直径不超过 [kGridAvatarMax], 但占位宽高与格子一致,
  /// 这样同一行卡片里的文字基线仍然对齐, 格子高度也不会和 delegate 算的差开。
  Widget _roundCover(String? url, double tileWidth) {
    final size = tileWidth < kGridAvatarMax ? tileWidth : kGridAvatarMax;
    return SizedBox(
      width: tileWidth,
      height: tileWidth,
      child: Center(
        child: CircleCover(url: url, size: size),
      ),
    );
  }

  /// MV 封面: 方形封面 + 右下角播放角标
  Widget _mvCover(String? url, double tileWidth) {
    return SizedBox(
      width: tileWidth,
      height: tileWidth,
      child: Stack(
        children: [
          Positioned.fill(
            child: CoverArt(url: url, size: tileWidth, radius: 8),
          ),
          const Positioned(right: 4, bottom: 4, child: _MvPlayBadge()),
        ],
      ),
    );
  }

  static String _mvSubtitle(SearchMv mv) {
    final count = mv.playCount;
    final parts = <String>[
      if (mv.artistName.isNotEmpty) mv.artistName,
      if (count != null && count > BigInt.zero)
        '${formatCountMagnitude(count.toInt())} 次播放',
    ];
    return parts.join(' · ');
  }

  /// 封面 + 名字 + 副标题的竖排卡片(艺人/专辑/歌单/播客/用户/MV 共用)
  Widget _gridCard(
    BuildContext context, {
    required double tileWidth,
    required VoidCallback onTap,
    required Widget cover,
    required String name,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: tileWidth,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            cover,
            const SizedBox(height: kCardGap),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 圆形头像(艺人/用户)在网格里的直径上限: 再宽也不放大,
/// 否则 2 列时一张头像就占满半屏。
const double kGridAvatarMax = 96;

/// MV 封面右下角的播放角标(深色半透明圆 + 白色三角)
class _MvPlayBadge extends StatelessWidget {
  const _MvPlayBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: const BoxDecoration(
        color: Color(0x8A000000),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.play_arrow, size: 16, color: Color(0xFFFFFFFF)),
    );
  }
}
