import 'package:flutter/material.dart';

import '../cover_art.dart';
import '../now_playing.dart';
import '../rust/api.dart' as rust;
import '../song_actions.dart';
import '../song_tile.dart' show SongTitleWithBadges;

/// 日推/历史日推/最近听过共用的曲目行: 序号(正在播换喇叭) + 封面 + 歌名徽标 + 艺人 + "..." 菜单.
class DiscoverSongRow extends StatelessWidget {
  const DiscoverSongRow({
    super.key,
    required this.song,
    required this.index,
    required this.onTap,
    this.source = SongActionSource.other,
  });

  final rust.SongDto song;
  final int index;
  final VoidCallback? onTap;

  /// 菜单来源(决定"..."菜单里"不感兴趣"是否显示)
  final SongActionSource source;

  @override
  Widget build(BuildContext context) {
    // 用户反馈(2026-11-14): 完整日推歌单里正在播放的那首没有高亮。
    // 现在统一读全局"正在播放"(src/now_playing.dart): 命中就把序号换成喇叭、
    // 歌名换成主色, 与歌单详情页/搜索结果同一套播放态语汇。
    return NowPlayingHighlight(
      songId: song.id,
      builder: (context, playing) => _buildRow(context, playing),
    );
  }

  Widget _buildRow(BuildContext context, bool playing) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    return ListTile(
      dense: true,
      selected: playing,
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            // token-ok: 序号列宽按 "两位数" 内容宽度定, 不是间距 token
            width: 22,
            child: playing
                ? Icon(Icons.volume_up, size: 16, color: scheme.primary)
                : Text('$index', style: theme.bodySmall),
          ),
          CoverArt(url: song.coverUrl, size: 40, radius: 4),
        ],
      ),
      // 歌名 + VIP/付费/无版权标记(标记固定宽度, 不会被歌名挤掉)
      title: SongTitleWithBadges(
        song: song,
        style: playing
            ? theme.bodyMedium?.copyWith(
                color: scheme.primary,
                fontWeight: FontWeight.w600,
              )
            : (song.playable ? null : TextStyle(color: scheme.outline)),
      ),
      subtitle: Text(song.artist, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: SongOverflowButton(song: song, size: 20, source: source),
      onTap: onTap,
    );
  }
}
