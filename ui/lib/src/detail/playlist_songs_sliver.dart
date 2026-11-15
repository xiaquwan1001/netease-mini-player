import 'package:flutter/material.dart';

import '../layout.dart' show kPagePadding, rowExtentFor;
import '../rust/api.dart' as rust;
import 'detail_shared.dart' show DetailSkeletonList;
import 'playlist_song_row.dart' show PlaylistSongRow;

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
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: kPagePadding,
            vertical: 20,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ),
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
        return PlaylistSongRow(
          song: song,
          index: i,
          playing: playingId == song.id,
          liked: liked.contains(song.id),
          onToggleLike: () => onToggleLike(song),
          onTap: () => onTapSong(song, i),
        );
      }, childCount: display.length),
    );
  }
}
