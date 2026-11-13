import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';
import 'format.dart' show formatDurationMs;
import 'section_header.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'song_tile.dart' show VipBadge, PaidBadge, UnplayableBadge;

/// 艺人主页的「区块」组件(与用户个人主页区分的核心):
/// 推荐单曲 / 专辑横滑 / 详细艺人弹层。只吃 DTO, 不发请求,
/// 数据与回调全部由 artist_page 注入(可测试)。

/// 推荐单曲区块: 详情接口带来的 top 5 首。
/// 徽标直接放在标题行(不放 AdaptiveTextRow.badges —— 窄屏下那组会被整组收起)。
class ArtistRecommendedSongsSection extends StatelessWidget {
  const ArtistRecommendedSongsSection({
    super.key,
    required this.songs,
    required this.totalCount,
    required this.onPlaySongs,
    required this.onSeeAll,
  });

  final List<rust.SongDto> songs;

  /// 全量歌曲数(文案用, 来自 musicCount)
  final BigInt totalCount;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '推荐单曲',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () => onPlaySongs(songs, 0),
                icon: const Icon(Icons.play_arrow, size: 18),
                label: const Text('播放全部'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
              ),
              SectionSeeAllButton(
                label: '查看全部 $totalCount 首 ›',
                onTap: onSeeAll,
              ),
            ],
          ),
        ),
        for (var i = 0; i < songs.length; i++)
          _ArtistRecommendSongRow(
            song: songs[i],
            index: i,
            onTap: songs[i].playable ? () => onPlaySongs(songs, i) : null,
          ),
      ],
    );
  }
}

/// 推荐单曲的一行: 封面 + (歌名+徽标 / 歌手·专辑) + 时长。
/// 标题/副标题都是 Expanded + ellipsis, 300dp 大字号不溢出。
class _ArtistRecommendSongRow extends StatelessWidget {
  const _ArtistRecommendSongRow({
    required this.song,
    required this.index,
    required this.onTap,
  });

  final rust.SongDto song;
  final int index;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final playable = song.playable;
    final grey = TextStyle(color: scheme.outline);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            // 序号: 统一两位宽度, 大字号也不挤压标题
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
            const SizedBox(width: 8),
            CoverArt(url: song.coverUrl, size: 44, radius: 4),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 徽标跟在歌名后面同一行, 各自完整显示(不被整组收起)
                  Row(
                    children: [
                      Expanded(
                        child: AdaptiveText(
                          song.name,
                          style: playable ? theme.textTheme.bodyMedium : grey,
                        ),
                      ),
                      if (playable && song.vip) const VipBadge(small: true),
                      if (playable && !song.vip && song.paid) const PaidBadge(),
                      if (!playable) const UnplayableBadge(),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: playable
                          ? scheme.onSurfaceVariant
                          : scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              formatDurationMs(song.durationMs),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
          ],
        ),
      ),
    );
  }
}

/// 专辑区块: 前 6 张横向滚动卡片。无专辑时整个区块不渲染(由调用方判断)。
class ArtistAlbumsSection extends StatelessWidget {
  const ArtistAlbumsSection({
    super.key,
    required this.albums,
    required this.totalCount,
    required this.onOpenAlbum,
    required this.onSeeAll,
  });

  final List<rust.AlbumBrief> albums;
  final BigInt totalCount;
  final void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 卡片高 = 封面 108 + 间距 4 + 名字/年份两行文字 + 底部 4。
    // 文字块必须按 textScaler 放大(固定 160 在 1.625 字号下纵向溢出 4px):
    // 名字 labelMedium(12) + 年份 labelSmall(11), 行高约 1.4。
    final scaler = MediaQuery.textScalerOf(context);
    final cardHeight =
        108 + 4 + scaler.scale(12) * 1.4 + scaler.scale(11) * 1.4 + 4;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: '专辑',
          trailing: SectionSeeAllButton(
            label: '全部 $totalCount 张 ›',
            onTap: onSeeAll,
          ),
        ),
        // 横向 ListView: 300dp 下天然可滚, 不参与竖向溢出
        SizedBox(
          height: cardHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: albums.length,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final album = albums[i];
              final year = album.publishTime > BigInt.zero
                  ? DateTime.fromMillisecondsSinceEpoch(
                      album.publishTime.toInt(),
                    ).year
                  : null;
              return SizedBox(
                width: 108,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onOpenAlbum == null
                      ? null
                      : () =>
                            onOpenAlbum!(album.id, album.name, album.coverUrl),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 108,
                        width: 108,
                        child: CoverArt(url: album.coverUrl, radius: 6),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        album.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium,
                      ),
                      Text(
                        year != null ? '$year' : ' ',
                        maxLines: 1,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 「详细艺人」弹层: 完整简介(可滚) + 统计 + 相似歌手胶囊。
/// 用 SheetHeader 而不是 AppBar(sheet 内容高度无界, AppBar 的 flex 会抛异常)。
Future<void> showArtistInfoSheet(
  BuildContext context, {
  required rust.ArtistDetailDto detail,
  required List<rust.Artist> similar,
  required void Function(rust.Artist artist) onOpenArtist,
}) {
  final theme = Theme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SheetHeader(
                title: '详细艺人资料',
                onClose: () => Navigator.of(sheetContext).pop(),
              ),
              const SizedBox(height: 8),
              // 简介可能很长: 弹层用 isScrollControlled + 固定高度上限后内部滚动
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${detail.albumCount} 个专辑 · ${detail.musicCount} 首歌曲',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (detail.briefDesc.trim().isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(
                          detail.briefDesc.trim(),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                      if (similar.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Text('相似歌手', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 8),
                        // 胶囊 Wrap: 横排放不下自动换行, 名字单行省略
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final a in similar)
                              ActionChip(
                                avatar: CircleCover(url: a.avatarUrl, size: 24),
                                label: Text(
                                  a.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onPressed: () {
                                  Navigator.of(sheetContext).pop();
                                  onOpenArtist(a);
                                },
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: const Text('关闭'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
