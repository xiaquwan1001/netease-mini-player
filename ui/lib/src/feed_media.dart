import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'rust/api.dart' as rust;
import 'song_tile.dart' show SongTitleWithBadges;

/// 动态配图: **只渲染用户自己附加的照片**, 并按数量决定排版.
///
/// 两条用户反馈都收敛在这里:
/// - 12: 「仅分享歌曲的动态, 不应该再次附带专辑/歌曲图片」 —— 分享类动态的
///   `images` 有时会带上内容本身的封面(与 [FeedEventDto.coverUrl] /
///   [SongDto.coverUrl] 相同), 这里把它们剔掉, 只在用户真的传了别的图时展示;
/// - 13: 「图片预览图太小, 应该随附图数量排版」 —— 1 张铺满卡片宽度(4:3),
///   2 张两列, 3 张及以上三列正方形(最多 9 张), 尺寸由可用宽度算, 不再是
///   固定 64dp 缩略图。
///
/// 详情页(list 卡片/用户主页摘要/动态详情)共用同一份排版, 避免"详情大图、
/// 列表小图"两套口径。
List<String> feedAttachedImages(rust.FeedEventDto event) {
  if (event.images.isEmpty) return const <String>[];
  // 内容自身的封面(分享单曲/专辑/歌单): 不算"用户附的图"
  final autoCovers = <String>{
    httpsImageUrl(event.coverUrl),
    httpsImageUrl(event.song?.coverUrl),
  }..remove('');
  final out = <String>[];
  for (final raw in event.images) {
    final url = httpsImageUrl(raw);
    if (url.isEmpty || autoCovers.contains(url)) continue;
    out.add(url);
  }
  return out;
}

/// 动态附图网格: 1 张铺满 / 2 张两列 / 3+ 三列(最多 9 张).
class FeedImageGrid extends StatelessWidget {
  const FeedImageGrid({
    super.key,
    required this.images,
    this.onTap,
    this.maxImages = 9,
  });

  /// 已经过滤过的图片直链(通常来自 [feedAttachedImages]).
  final List<String> images;

  /// 点击第 i 张(默认打开全屏查看器)
  final void Function(int index)? onTap;
  final int maxImages;

  static const double _gap = 6;

  @override
  Widget build(BuildContext context) {
    final urls = images.take(maxImages).toList(growable: false);
    if (urls.isEmpty) return const SizedBox.shrink();
    void open(int i) {
      final handler = onTap;
      if (handler != null) {
        handler(i);
      } else {
        showImageViewer(context, urls: urls, initialIndex: i);
      }
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        if (urls.length == 1) {
          // 单图: 铺满可用宽度, 4:3 裁切(不再是 64dp 小缩略图)
          return GestureDetector(
            onTap: () => open(0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AspectRatio(
                aspectRatio: 4 / 3,
                child: NetImage(
                  url: urls.first,
                  width: width,
                  height: width * 3 / 4,
                  radius: 8,
                ),
              ),
            ),
          );
        }
        final columns = urls.length == 2 ? 2 : 3;
        final size = (width - _gap * (columns - 1)) / columns;
        return Wrap(
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (var i = 0; i < urls.length; i++)
              GestureDetector(
                onTap: () => open(i),
                child: NetImage(
                  url: urls[i],
                  width: size,
                  height: size,
                  radius: 6,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 单曲 mini 卡(动态卡片/用户主页/艺人页共用): CoverArt + 歌名/艺人 + play 图标,
/// 点击播放这一首(不可播放时置灰且不可点)。
class FeedSongMiniCard extends StatelessWidget {
  const FeedSongMiniCard({
    super.key,
    required this.song,
    this.coverUrl,
    required this.onPlaySongs,
  });

  final rust.SongDto song;
  final String? coverUrl;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: song.playable ? () => onPlaySongs([song], 0) : null,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              CoverArt(url: song.coverUrl ?? coverUrl, size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SongTitleWithBadges(
                      song: song,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: song.playable ? null : scheme.outline,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.play_arrow,
                size: 24,
                color: song.playable ? scheme.primary : scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 16:9 视频封面: NetImage(coverUrl 兜底) + 居中白色播放圆标 + 右上角"视频"标签。
/// 动态卡片/用户主页/艺人页共用(点击交给系统播放器打开直链)。
class FeedVideoThumb extends StatelessWidget {
  const FeedVideoThumb({
    super.key,
    required this.url,
    this.coverUrl,
    required this.onOpenUrl,
  });

  final String url;
  final String? coverUrl;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: GestureDetector(
        onTap: () => onOpenUrl(url),
        child: Stack(
          fit: StackFit.expand,
          children: [
            NetImage(
              url: coverUrl,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              icon: Icons.videocam_outlined,
            ),
            // 半透明暗化, 突出播放按钮
            const ColoredBox(color: Colors.black26),
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: Colors.white54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '视频',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
