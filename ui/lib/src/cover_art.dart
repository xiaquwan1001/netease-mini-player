import 'package:flutter/material.dart';



/// 网易云封面/图片直链常是明文 http; CDN 同路径支持 https(证书覆盖 *.music.126.net)。
/// Android 边拉边播/图片加载统一升级到 https, 避免明文 80 被中间设备拦成空 body。
String httpsImageUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return url;
  return uri.replace(scheme: 'https').toString();
}

/// 通用网络图片: 封面/动态配图/头像/背景图都走这里.
/// 统一升级 https、圆角裁剪、失败占位(不抛异常)。
class NetImage extends StatelessWidget {
  const NetImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius = 0,
    this.placeholder,
    this.icon = Icons.music_note,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double radius;
  final Widget? placeholder;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = width ?? height ?? 48;
    final fallback = placeholder ??
        Container(
          width: width,
          height: height,
          color: scheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: Icon(icon, size: size * 0.42, color: scheme.outline),
        );
    final src = httpsImageUrl(url);
    if (src.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Image.network(
        neteaseThumbUrl(src, width: width, height: height),
        headers: kImageHeaders,
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

/// 圆形头像(歌手/评论/动态共用)
class CircleCover extends StatelessWidget {
  const CircleCover({super.key, required this.url, this.size = 40, this.icon = Icons.person});

  final String? url;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final src = httpsImageUrl(url);
    if (src.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: scheme.surfaceContainerHighest, shape: BoxShape.circle),
        child: Icon(icon, size: size * 0.5, color: scheme.outline),
      );
    }
    return ClipOval(
      child: Image.network(
        neteaseThumbUrl(src, width: size),
        headers: kImageHeaders,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) {
          return Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: size * 0.5, color: scheme.outline),
          );
        },
      ),
    );
  }
}

/// 全屏看大图(动态配图 / 专辑封面): 左右滑动切换, 点任意处关闭.
Future<void> showImageViewer(
  BuildContext context, {
  required List<String> urls,
  int initialIndex = 0,
}) {
  final images = [for (final u in urls) if (httpsImageUrl(u).isNotEmpty) httpsImageUrl(u)];
  if (images.isEmpty) return Future.value();
  final start = initialIndex.clamp(0, images.length - 1);
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (dialogContext) => GestureDetector(
      onTap: () => Navigator.of(dialogContext).pop(),
      child: PageView.builder(
        controller: PageController(initialPage: start),
        itemCount: images.length,
        itemBuilder: (context, i) => InteractiveViewer(
          child: Center(
            child: Image.network(
              images[i],
              headers: kImageHeaders,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const Icon(Icons.broken_image, color: Colors.white54, size: 48),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 图片请求头: 网易云 CDN 对 `Dart/3.x (dart:io)` 这个默认 UA 直接回 403
/// (2026-11-06 实测: 同一 URL, Dart UA 403 / 浏览器 UA 200), 必须显式覆盖.
const Map<String, String> kImageHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'Referer': 'https://music.163.com/',
};

/// 缩略图: 网易云 CDN 支持 `?param=NxN` 服务端裁剪.
/// 列表里直接拉 1~2MB 原图会很慢(模拟器/移动网络尤其明显), 统一按显示尺寸取缩略图。
String neteaseThumbUrl(String url, {num? width, num? height}) {
  if (url.isEmpty) return url;
  // 全宽图片(width: double.infinity)不能拿去算 param, 否则 Infinity.toInt() 直接抛异常
  final dims = <num>[
    if (width != null && width.isFinite) width,
    if (height != null && height.isFinite) height,
  ];
  if (dims.isEmpty) return url;
  final px = dims.reduce((a, b) => a > b ? a : b).round();
  if (px <= 0) return url;
  final sep = url.contains('?') ? '&' : '?';
  return '$url${sep}param=${px}y$px';
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
        neteaseThumbUrl(src, width: size),
        headers: kImageHeaders,
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
