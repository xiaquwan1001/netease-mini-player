import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'cover_art.dart';
import 'format.dart' show formatDurationMs;
import 'rust/api.dart' as rust;
import 'song_tile.dart' show VipBadge, PaidBadge, UnplayableBadge;

/// 艺人主页的「区块」组件。只吃 DTO, 不发请求,
/// 数据与回调全部由 artist_page 注入(可测试)。
///
/// 2026-11 需求 13/9 后本文件只剩两件东西:
/// - [ArtistRecommendedSongsSection]: 「推荐单曲」**tab** 的内容(不再在信息区重复一份);
/// - [SimilarArtistsRow]: 相似艺人横排(可拖拽, 不做自动滚动/轮播)。
/// 信息区里的「专辑横滑」与「详细艺人」弹层已删除(与专辑 tab/简介区完全重复)。

/// 推荐单曲列表(艺人详情页「推荐单曲」tab 的内容): 播放全部 + top N 行。
/// 徽标直接放在标题行(不放 AdaptiveTextRow.badges —— 窄屏下那组会被整组收起)。
class ArtistRecommendedSongsSection extends StatelessWidget {
  const ArtistRecommendedSongsSection({
    super.key,
    required this.songs,
    required this.onPlaySongs,
  });

  final List<rust.SongDto> songs;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 「播放全部」必须左顶格: 之前是 IconButton(图标居中在 32dp 的盒子里,
        // 再叠 left:4 的内边距), 视觉上左边空出一截(用户反馈)。这里改成
        // InkWell + Row, 图标就是行首第一个像素, 不再有隐形留白。
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: '播放全部',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => onPlaySongs(songs, 0),
                child: Semantics(
                  button: true,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.play_arrow,
                          size: 20,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 2),
                        Text('播放全部', style: theme.textTheme.labelMedium),
                      ],
                    ),
                  ),
                ),
              ),
            ),
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

/// 推荐单曲的一行: 封面 + (歌名+徽标 / 艺人·专辑) + 时长。
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

/// 相似艺人横排(需求 9): 头像在上 / 名字在下(单行省略), 横向 ListView 由**用户
/// 手动拖拽**。禁止自动滚动、轮播、PageView —— 这里没有 Timer、没有 ScrollController
/// 驱动、没有 animateTo, 静态 ListView 只在用户拖动时移动。
///
/// 未登录/接口失败时由调用方整块不渲染(空列表时本组件也返回 [SizedBox.shrink],
/// 双保险: 少一层"空标题"的可能)。
class SimilarArtistsRow extends StatelessWidget {
  const SimilarArtistsRow({
    super.key,
    required this.artists,
    required this.onOpen,
  });

  final List<rust.Artist> artists;
  final void Function(rust.Artist artist) onOpen;

  /// 单项宽度(需求: 72~80dp)。头像 48 居中, 名字与分量同宽。
  static const double itemWidth = 72;

  /// 头像直径(与 itemWidth 一起决定视觉节奏)
  static const double avatarSize = 48;

  @override
  Widget build(BuildContext context) {
    if (artists.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // 高度 = 头像 + 间距 + 名字行(按 textScaler 放大)。名字只有一行,
    // 行高按 1.5 估 + 2dp 余量(与 coverGridDelegate 同一口径: 1.45 实测在
    // 300dp x1.625 下会竖溢 0.08px)。
    final labelHeight = scaler.scale(11) * 1.5 + 2;
    return SizedBox(
      height: avatarSize + 4 + labelHeight,
      child: ListView.separated(
        // 横向 + 手动拖拽: 不设 controller/physics 抖动, 不做任何自动滚动
        scrollDirection: Axis.horizontal,
        itemCount: artists.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = artists[i];
          return SizedBox(
            width: itemWidth,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onOpen(a),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleCover(url: a.avatarUrl, size: avatarSize),
                  const SizedBox(height: 4),
                  // 单行 + ellipsis: 300dp + textScale 1.625 也不溢出
                  Text(
                    a.name,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
