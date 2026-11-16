import 'package:flutter/material.dart';

import '../error_views.dart' show InlineError;
import '../layout.dart' show kPagePadding, kPageRowPadding, rowExtentFor;
import '../rust/api.dart' as rust;
import '../song_actions.dart' show SongActionSource;
import '../song_tile.dart' show SongRow;
import 'detail_shared.dart' show DetailSkeletonList;

/// 歌单曲目列表(四态: 骨架 / 错误行 / 空态 / 定高列表), 作为 sliver 直接进
/// [CustomScrollView]。行高随系统字号放大(rowExtentFor, 基准 56)。
/// 点行后的动作(起播/移出)由 [onTapSong] 回给页面, 这里只管渲染。
class PlaylistSongsSliver extends StatelessWidget {
  const PlaylistSongsSliver({
    super.key,
    required this.songs,
    required this.error,
    required this.display,
    required this.filter,
    required this.special,
    required this.hiddenCount,
    required this.playingId,
    required this.liked,
    required this.listKey,
    required this.onRetry,
    required this.onToggleLike,
    required this.onTapSong,
  });

  /// 原始曲目(null = 还没回来)
  final List<rust.SongDto>? songs;

  /// 加载失败文案(非空时只显示一行错误 + 重试)
  final String? error;

  /// 已按"无版权规则 + 搜索框过滤"处理过的列表
  final List<rust.SongDto> display;
  final String filter;

  /// "我喜欢的音乐"页(空态文案不同)
  final bool special;
  final int hiddenCount;

  /// 正在播放的曲目(页内乐观态优先)
  final BigInt? playingId;

  /// 红心集合(页面内副本)
  final Set<BigInt> liked;

  /// 曲目列表节点的 key(页面用它量"定位正在播放"的起点)
  final GlobalKey listKey;

  final VoidCallback onRetry;
  final void Function(rust.SongDto song) onToggleLike;
  final void Function(rust.SongDto song, int index) onTapSong;

  @override
  Widget build(BuildContext context) {
    if (songs == null && error == null) {
      return const SliverToBoxAdapter(child: DetailSkeletonList());
    }
    if (error != null) {
      // 错误行统一走 InlineError(文案已由页面套过 friendlyError),
      // 与页面级/区块级错误态同一份实现, 不再手写 Row + 重试按钮。
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kPagePadding,
            vertical: 20,
          ),
          child: InlineError(message: error!, onRetry: onRetry),
        ),
      );
    }
    if (display.isEmpty) {
      final message = filter.trim().isNotEmpty
          ? '没有匹配 "${filter.trim()}" 的曲目'
          : (hiddenCount > 0
                ? '这里没有可播放的曲目($hiddenCount 首无版权已隐藏)'
                : (special ? '还没有喜欢的歌曲' : '这个歌单是空的'));
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kPagePadding,
            vertical: 32,
          ),
          child: Center(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
      );
    }
    return SliverFixedExtentList(
      key: listKey,
      // 行高随系统字号放大: 定 56 时 1.625 字号下「标题 + 副标题」竖溢 12dp
      itemExtent: rowExtentFor(context),
      delegate: SliverChildBuilderDelegate((context, i) {
        final song = display[i];
        final theme = Theme.of(context);
        return SongRow(
          song: song,
          // 序号两位右对齐(1 起); 正在播放时换成喇叭
          indexText: '${i + 1}'.padLeft(2),
          indexWidth: 26,
          indexAlign: TextAlign.right,
          indexGap: 10,
          // 页内乐观态(playingId)与全局"正在播放"取并集: 在别处换了歌再回来也要跟着走
          active: playingId == song.id,
          unionWithNowPlaying: true,
          playingTint: true,
          // 保持原行为: 单行 ellipsis, 不跑马灯
          titleMarquee: false,
          // 徽标在副标题行: 300dp 手机上标题区只剩 ~100dp, 徽标会被整组收起
          badgesInSubtitle: true,
          subtitleStyle: theme.textTheme.labelSmall?.copyWith(
            color: song.playable ? null : theme.colorScheme.outline,
          ),
          // 行尾整组封顶 45%: 触顶时先截断时长
          capTrailing: true,
          liked: liked.contains(song.id),
          onToggleLike: () => onToggleLike(song),
          menuSource: SongActionSource.playlist,
          // 与 SectionHeader/推荐页同一栅格: 左 12 贴页面线, 右 4 给行尾按钮
          // (列表行审计 C 级: 口径收进 layout.dart)
          padding: kPageRowPadding,
          onTap: () => onTapSong(song, i),
        );
      }, childCount: display.length),
    );
  }
}
