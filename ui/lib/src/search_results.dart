import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'library_view.dart';
import 'rust/api.dart' as rust;
import 'song_tile.dart';

/// 综合搜索结果: 单曲 / 歌手 / 专辑 / 歌单 / 播客.
///
/// 分类**横向**排(可横滑的 ChoiceChip 条), 一次只渲染一个分类:
/// 之前五个分区纵向堆叠, 想找"歌手"要先划过整页单曲(用户反馈必须往下翻)。
/// 空分类不出现; 全部为空时居中提示。
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

  /// 行尾 "..." 菜单
  final void Function(rust.SongDto)? onMenu;

  @override
  State<SearchResultsView> createState() => _SearchResultsViewState();
}

/// 五个分类(顺序即 chip 顺序)
enum _Section { songs, artists, albums, playlists, podcasts }

extension on _Section {
  String get label => switch (this) {
    _Section.songs => '单曲',
    _Section.artists => '歌手',
    _Section.albums => '专辑',
    _Section.playlists => '歌单',
    _Section.podcasts => '播客',
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

    final available = <_Section>[
      if (visible.isNotEmpty) _Section.songs,
      if (bundle.artists.isNotEmpty) _Section.artists,
      if (bundle.albums.isNotEmpty) _Section.albums,
      if (bundle.playlists.isNotEmpty) _Section.playlists,
      if (bundle.podcasts.isNotEmpty) _Section.podcasts,
    ];
    if (available.isEmpty) {
      return Center(
        child: Text(
          '没有找到相关内容',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    // 结果包变了以后旧选择可能已经不存在(比如新搜索没有专辑) ⇒ 回落到第一个
    final selected = available.contains(_selected)
        ? _selected!
        : available.first;

    return Column(
      children: [
        _sectionBar(context, available, selected),
        Expanded(child: _buildSection(context, selected, visible, hidden)),
      ],
    );
  }

  /// 横向分类条: 可横滑, 窄屏(300dp)+大字也不会挤成两行/溢出
  Widget _sectionBar(
    BuildContext context,
    List<_Section> available,
    _Section selected,
  ) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: available.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final s = available[i];
          return ChoiceChip(
            label: Text(s.label),
            selected: s == selected,
            // 已选中时再点不做事(避免重建丢滚动位置)
            onSelected: (_) {
              if (_selected != s) setState(() => _selected = s);
            },
            visualDensity: VisualDensity.compact,
          );
        },
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
    switch (section) {
      case _Section.songs:
        return ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            // 单曲行要"左右占满": 不额外加水平留白, 提示行自己补
            if (hidden > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
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
        return _cardWrap(context, [
          for (final a in bundle.artists)
            _card(
              context,
              width: 92,
              onTap: () => widget.onOpenArtist(a),
              cover: CircleCover(url: a.avatarUrl, size: 72),
              name: a.name,
              subtitle: a.alias.isNotEmpty ? a.alias : '${a.albumCount} 张专辑',
            ),
        ]);
      case _Section.albums:
        return _cardWrap(context, [
          for (final al in bundle.albums)
            _card(
              context,
              width: 118,
              onTap: () => widget.onOpenAlbum(al),
              cover: CoverArt(url: al.coverUrl, size: 118, radius: 8),
              name: al.name,
              subtitle: '${al.artist} · ${al.trackCount} 首',
            ),
        ]);
      case _Section.playlists:
        return _cardWrap(context, [
          for (final p in bundle.playlists)
            _card(
              context,
              width: 118,
              onTap: () => widget.onOpenPlaylist(p),
              cover: CoverArt(url: p.coverUrl, size: 118, radius: 8),
              name: p.name,
              subtitle: '${p.creatorName} · ${p.trackCount} 首',
            ),
        ]);
      case _Section.podcasts:
        return _cardWrap(context, [
          for (final p in bundle.podcasts)
            _card(
              context,
              width: 118,
              onTap: () => widget.onOpenPodcast(p),
              cover: CoverArt(url: p.coverUrl, size: 118, radius: 8),
              name: p.name,
              subtitle: '${p.djName} · ${p.programCount} 集',
            ),
        ]);
    }
  }

  /// 卡片网格: Wrap 自动换行, 单分类时横向铺满(比固定高度的横滑条更省纵向空间)
  Widget _cardWrap(BuildContext context, List<Widget> items) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [Wrap(spacing: 10, runSpacing: 12, children: items)],
    );
  }

  /// 封面 + 名字 + 副标题 的竖排卡片(歌手/专辑/歌单/播客共用)
  Widget _card(
    BuildContext context, {
    required double width,
    required VoidCallback onTap,
    required Widget cover,
    required String name,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: width,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            cover,
            const SizedBox(height: 4),
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
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
