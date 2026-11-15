import 'package:flutter/material.dart';

import '../async_view.dart';
import '../error_views.dart' show FullError;
import '../net_retry.dart' show friendlyError;
import '../rust/api.dart' as rust;
import '../song_actions.dart';
import '../state_views.dart';
import '../song_tile.dart' show SongRow, SongRowLayout, SongRowSubtitle;
import 'discover_types.dart';

/// 「推荐歌曲」页签: 一次全量返回, 点歌只换队列、不退出日推页.
///
/// 整页四态收敛到 [AsyncView](与 VIP/勋章墙/专辑页同一口径):
/// 加载 = 整页 LoadingView, 出错 = 整页 FullError(文案走 friendlyError),
/// 空 = 带图标的 EmptyView; keepAlive 保住"切走页签再回来不重新取数"。
class DailySongsTab extends StatelessWidget {
  const DailySongsTab({super.key, required this.load, required this.onPlay});

  final SongListLoader load;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<rust.SongDto>>(
      load: load,
      keepAlive: true,
      emptyText: '今天没有推荐歌曲',
      loadingBuilder: (_) => const LoadingView(),
      emptyBuilder: (_) =>
          const EmptyView(icon: Icons.music_note_outlined, title: '今天没有推荐歌曲'),
      errorBuilder: (_, error, retry) =>
          FullError(message: friendlyError(error), onRetry: retry),
      // 非分页: 每日推荐歌曲一次全量返回, 接口无分页
      builder: (context, songs, _) => ListView.builder(
        itemCount: songs.length,
        itemBuilder: (context, i) {
          final s = songs[i];
          return SongRow(
            song: s,
            layout: SongRowLayout.tile,
            indexText: '${i + 1}',
            indexWidth: 22,
            indexAlign: TextAlign.start,
            indexGap: 0,
            coverSize: 40,
            subtitle: SongRowSubtitle.artist,
            showDuration: false,
            // 每日推荐 tab: "..."菜单同样允许"不感兴趣"
            menuSource: SongActionSource.dailyRecommend,
            // 点歌只开始播放, 不退出日推页(与歌单详情页一致)。
            onTap: s.playable ? () => onPlay(songs, i) : null,
          );
        },
      ),
    );
  }
}
