import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'library_view.dart';
import 'rust/api.dart' as rust;
import 'song_tile.dart';

/// 综合搜索结果: 单曲 / 歌手 / 专辑 / 歌单 / 播客 五个分区。
/// 空板块整段不渲染; 全部为空时居中提示。
class SearchResultsView extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = visibleSongs(bundle.songs, liked);
    final hidden = hiddenUnplayableCount(bundle.songs, liked);

    final empty =
        visible.isEmpty &&
        bundle.artists.isEmpty &&
        bundle.albums.isEmpty &&
        bundle.playlists.isEmpty &&
        bundle.podcasts.isEmpty;
    if (empty) {
      return Center(
        child: Text(
          '没有找到相关内容',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }

    final children = <Widget>[];

    // ---- 单曲 ----
    if (visible.isNotEmpty) {
      children.add(
        _sectionTitle(context, '单曲', suffix: '共${bundle.songTotal}首'),
      );
      if (hidden > 0) {
        children.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Text(
              '已隐藏 $hidden 首无版权曲目',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        );
      }
      children.addAll([
        for (final s in visible)
          SongTile(
            song: s,
            active: currentTrackId == s.id,
            liked: liked.contains(s.id),
            onTap: () => onPlaySong(s),
            onMenu: onMenu == null ? null : () => onMenu!(s),
          ),
      ]);
    }

    // ---- 歌手 ----
    if (bundle.artists.isNotEmpty) {
      children.add(_sectionTitle(context, '歌手'));
      children.add(
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: bundle.artists.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final a = bundle.artists[i];
              final sub = a.alias.isNotEmpty ? a.alias : '${a.albumCount} 张专辑';
              return _card(
                context,
                width: 92,
                onTap: () => onOpenArtist(a),
                cover: CircleCover(url: a.avatarUrl, size: 72),
                name: a.name,
                subtitle: sub,
              );
            },
          ),
        ),
      );
    }

    // ---- 专辑 ----
    if (bundle.albums.isNotEmpty) {
      children.add(_sectionTitle(context, '专辑'));
      children.add(
        _coverRow(
          context,
          items: [
            for (final al in bundle.albums)
              _card(
                context,
                width: 118,
                onTap: () => onOpenAlbum(al),
                cover: CoverArt(url: al.coverUrl, size: 118, radius: 8),
                name: al.name,
                subtitle: '${al.artist} · ${al.trackCount} 首',
              ),
          ],
        ),
      );
    }

    // ---- 歌单 ----
    if (bundle.playlists.isNotEmpty) {
      children.add(_sectionTitle(context, '歌单'));
      children.add(
        _coverRow(
          context,
          items: [
            for (final p in bundle.playlists)
              _card(
                context,
                width: 118,
                onTap: () => onOpenPlaylist(p),
                cover: CoverArt(url: p.coverUrl, size: 118, radius: 8),
                name: p.name,
                subtitle: '${p.creatorName} · ${p.trackCount} 首',
              ),
          ],
        ),
      );
    }

    // ---- 播客 ----
    if (bundle.podcasts.isNotEmpty) {
      children.add(_sectionTitle(context, '播客'));
      children.add(
        _coverRow(
          context,
          items: [
            for (final p in bundle.podcasts)
              _card(
                context,
                width: 118,
                onTap: () => onOpenPodcast(p),
                cover: CoverArt(url: p.coverUrl, size: 118, radius: 8),
                name: p.name,
                subtitle: '${p.djName} · ${p.programCount} 集',
              ),
          ],
        ),
      );
    }

    // 单曲行要"左右占满"(用户反馈文字横向空间不足): 外层不再加 12dp 左右留白,
    // 标题/提示/横滑卡片各自补回自己的水平内边距。
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: children,
    );
  }

  Widget _sectionTitle(BuildContext context, String title, {String? suffix}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          if (suffix != null) ...[
            const SizedBox(width: 6),
            Text(
              suffix,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _coverRow(BuildContext context, {required List<Widget> items}) {
    return SizedBox(
      height: 176,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) => items[i],
      ),
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
