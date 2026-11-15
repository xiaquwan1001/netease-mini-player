import 'package:flutter/material.dart';

import '../adaptive_text_row.dart';
import '../format.dart' show formatDurationMs;
import '../now_playing.dart';
import '../rust/api.dart' as rust;
import '../song_actions.dart';
import '../song_tile.dart';

/// 固定行高(基准 56, 随字号放大)的曲目行: 序号(正在播换 volume_up) + 歌名 + 艺人·专辑 + 时长 + 红心
class PlaylistSongRow extends StatelessWidget {
  const PlaylistSongRow({
    super.key,
    required this.song,
    required this.index,
    required this.playing,
    required this.liked,
    required this.onToggleLike,
    required this.onTap,
  });

  final rust.SongDto song;
  final int index;
  final bool playing;
  final bool liked;
  final VoidCallback onToggleLike;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 页面自己算出来的 playing(本地乐观态/进入页面时的当前曲目) 与全局"正在播放"
    // 取并集: 在别处换了歌再回来看这个歌单, 高亮也要跟着走。
    return NowPlayingHighlight(
      songId: song.id,
      builder: (context, nowPlaying) =>
          _buildRow(context, playing || nowPlaying),
    );
  }

  Widget _buildRow(BuildContext context, bool playing) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    final grey = TextStyle(color: scheme.outline);
    final titleStyle = playing
        ? theme.bodyMedium?.copyWith(
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          )
        : (song.playable ? theme.bodyMedium : grey);
    return InkWell(
      onTap: onTap,
      child: Container(
        color: playing ? scheme.primary.withValues(alpha: 0.10) : null,
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 0),
        // 行尾三件(时长 + 红心 + 更多)是全仓最宽 trailing: 不封顶时 300dp 下
        // 标题区只剩 ~117dp(红心/更多按钮还会各自吃到默认 48dp)。
        // 与 SectionHeader 同口径给行尾封顶, 宽度不够时先截断时长。
        child: LayoutBuilder(
          builder: (context, constraints) {
            final maxTrailingWidth = constraints.maxWidth.isFinite
                ? constraints.maxWidth * 0.45
                : double.infinity;
            return Row(
              children: [
                SizedBox(
                  // token-ok: 名次列宽由 "两位数字 + 右对齐" 的内容宽度决定, 不是间距
                  width: 26,
                  child: playing
                      ? Icon(Icons.volume_up, size: 16, color: scheme.primary)
                      : Text(
                          '${index + 1}'.padLeft(2),
                          textAlign: TextAlign.right,
                          style: theme.bodySmall?.copyWith(
                            color: scheme.outline,
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 窄宽降级走共享组件 AdaptiveTextRow(Expanded + 单行).
                      // 徽标不放标题行: 300dp 手机上标题区只剩 ~100dp, 徽标会被整组收起
                      // (用户反馈"歌曲没有 VIP 标记"); 挪到副标题行, 任何宽度都可见.
                      AdaptiveTextRow(
                        title: song.name,
                        style: titleStyle,
                        // 保持原行为: 单行 ellipsis, 不跑马灯.
                        marquee: false,
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (song.playable && song.vip)
                            const VipBadge(small: true),
                          if (song.playable && !song.vip && song.paid)
                            const PaidBadge(),
                          if (!song.playable) const UnplayableBadge(),
                          Expanded(
                            child: Text(
                              '${song.artist} · ${song.album}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.labelSmall?.copyWith(
                                color: song.playable ? null : scheme.outline,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxTrailingWidth),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 时长是弹性项: 行尾触到上限时先截断它, 歌名/徽标不被挤掉
                      // (与 SongTile 窄屏优先牺牲时长的口径一致)。
                      Flexible(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            formatDurationMs(song.durationMs),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.bodySmall?.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ),
                      ),
                      // 命中区仍是 48dp 高, 宽度收到 40dp(与 SongTile 行尾一致):
                      // 两枚按钮省下 16dp 给标题区。
                      IconButton(
                        tooltip: liked ? '取消喜欢' : '喜欢',
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        style: const ButtonStyle(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 48,
                        ),
                        icon: Icon(
                          liked ? Icons.favorite : Icons.favorite_border,
                          size: 20,
                          color: liked ? scheme.primary : null,
                        ),
                        onPressed: onToggleLike,
                      ),
                      SongOverflowButton(
                        song: song,
                        size: 20,
                        source: SongActionSource.playlist,
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
