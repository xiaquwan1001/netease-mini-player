import 'package:flutter/material.dart';

import '../format.dart' show formatDurationMs;
import '../now_playing.dart';
import '../rust/api_all.dart' as rust;
import '../song_actions.dart';

/// 固定行高(基准 56, 随字号放大)的节目行: 节目名 + DJ · 时长
class PodcastProgramRow extends StatelessWidget {
  const PodcastProgramRow({
    super.key,
    required this.program,
    required this.onTap,
    this.onInfo,
  });

  final rust.PodcastProgramDto program;
  final VoidCallback onTap;

  /// 打开单集详情(没有音频本体的单集也给这个入口)
  final VoidCallback? onInfo;

  @override
  Widget build(BuildContext context) {
    // 用户反馈: 播客单集正在放的时候列表里要能认出来 —— 节目播放的其实是它
    // 对应的曲目(mainSong), 所以按 program.song.id 判断"是不是正在播的这集"。
    return NowPlayingHighlight(
      songId: program.song?.id,
      builder: (context, playing) => _buildRow(context, playing),
    );
  }

  Widget _buildRow(BuildContext context, bool playing) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    final song = program.song;
    // 长按/右键 = 这一集的歌曲菜单(与行尾"..."同一个面板, 来源 radio)。
    final host = song == null ? null : AppActions.maybeOf(context);
    VoidCallback? openMenu;
    if (song != null && host != null) {
      openMenu = () => showSongActionsSheet(
        context,
        song,
        host,
        source: SongActionSource.radio,
      );
    }
    return InkWell(
      onTap: onTap,
      onLongPress: openMenu,
      // 鼠标右键与长按同一语义(桌面端没有长按手势)
      onSecondaryTap: openMenu,
      child: Padding(
        padding: const EdgeInsets.only(left: 16, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (playing) ...[
                        Icon(Icons.volume_up, size: 14, color: scheme.primary),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          program.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: playing
                              ? theme.bodyMedium?.copyWith(
                                  color: scheme.primary,
                                  fontWeight: FontWeight.w600,
                                )
                              : theme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (program.djName.isNotEmpty) program.djName,
                      formatDurationMs(program.durationMs),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (onInfo != null)
              IconButton(
                icon: const Icon(Icons.info_outline, size: 20),
                tooltip: '节目详情',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                onPressed: onInfo,
              ),
            if (song != null)
              SongOverflowButton(
                song: song,
                size: 20,
                source: SongActionSource.radio,
              ),
          ],
        ),
      ),
    );
  }
}
