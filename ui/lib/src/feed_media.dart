import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'rust/api.dart' as rust;

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
