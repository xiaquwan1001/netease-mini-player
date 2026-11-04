import 'package:flutter/material.dart';

/// 网易云封面/图片直链常是明文 http; CDN 同路径支持 https(证书覆盖 *.music.126.net)。
/// Android 边拉边播/图片加载统一升级到 https, 避免明文 80 被中间设备拦成空 body。
String httpsImageUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return url;
  return uri.replace(scheme: 'https').toString();
}

/// 专辑封面(列表/播放条/歌单/播客通用).
/// 加载失败/无地址时退化成音符占位, 不抛异常也不占位空白。
class CoverArt extends StatelessWidget {
  const CoverArt({
    super.key,
    required this.url,
    this.size = 44,
    this.radius = 6,
  });

  final String? url;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final src = httpsImageUrl(url);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.music_note, size: size * 0.5, color: scheme.outline),
    );
    if (src.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        src,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}
