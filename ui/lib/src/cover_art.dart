import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 网易云封面/图片直链常是明文 http; CDN 同路径支持 https(证书覆盖 *.music.126.net)。
/// Android 边拉边播/图片加载统一升级到 https, 避免明文 80 被中间设备拦成空 body。
String httpsImageUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return url;
  return uri.replace(scheme: 'https').toString();
}

/// 图片请求头: 网易云 CDN 对 `Dart/3.x (dart:io)` 这个默认 UA 直接回 403
/// (2026-11-06 实测: 同一 URL, Dart UA 403 / 浏览器 UA 200), 必须显式覆盖.
///
/// 注意: 不能靠 `Image.network(headers: ...)` 来覆盖 UA —— NetworkImage 用的是
/// `HttpHeaders.add`, 会**追加**而不是替换 HttpClient 预置的 `Dart/3.x (dart:io)`,
/// 于是发出去的是 "Dart/3.9 (dart:io), Mozilla/..." 这种拼接值, CDN 照样 403
/// (2026-11-06 logcat 实测: 48 张图全部 statusCode 403)。所以这里自己实现
/// ImageProvider, 用 `HttpClient.userAgent` 彻底替换默认 UA。
const String kImageUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

/// 兼容旧引用(有些调用点可能还在用); 实际请求由 [_UaNetworkImage] 发.
const Map<String, String> kImageHeaders = {
  'User-Agent': kImageUserAgent,
  'Referer': 'https://music.163.com/',
};

/// 带正确 UA 的网络图片 Provider.
///
/// 用 `==`/`hashCode` 按 URL 判等: Flutter 的 ImageCache 以 provider 为 key,
/// 因此同一 URL 只会下载/解码一次, tab 切换或列表重建时直接命中缓存,
/// 不再出现"占位符一闪一闪"。
@immutable
class _UaNetworkImage extends ImageProvider<_UaNetworkImage> {
  const _UaNetworkImage(this.url);

  final String url;

  /// 始终 1.0: 不接收外部参数, 保证同一 URL 的 provider 严格相等(命中 ImageCache)
  static const double scale = 1.0;

  /// 独占一个 HttpClient, 把默认 UA 换成浏览器 UA(不是追加, 是整体替换)
  static final HttpClient _client = HttpClient()
    ..userAgent = kImageUserAgent
    ..connectionTimeout = const Duration(seconds: 15);

  /// 已下载的原始字节(简单 LRU, 200 张上限): 避免 provider 重建时重复拉图.
  static final Map<String, Uint8List> _bytes = <String, Uint8List>{};

  static Future<Uint8List> _fetch(String url) async {
    final cached = _bytes[url];
    if (cached != null) return cached;
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.refererHeader, 'https://music.163.com/');
    final resp = await req.close();
    if (resp.statusCode != HttpStatus.ok) {
      // 把 body 丢掉, 否则连接不会复用
      await resp.drain<void>();
      throw NetworkImageLoadException(statusCode: resp.statusCode, uri: Uri.parse(url));
    }
    final bytes = await consolidateHttpClientResponseBytes(resp);
    if (_bytes.length >= 200) _bytes.remove(_bytes.keys.first);
    _bytes[url] = bytes;
    return bytes;
  }

  @override
  Future<_UaNetworkImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_UaNetworkImage>(this);

  @override
  ImageStreamCompleter loadImage(_UaNetworkImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(key, decode),
      scale: scale,
    );
  }

  Future<ui.Codec> _loadAsync(_UaNetworkImage key, ImageDecoderCallback decode) async {
    final bytes = await _fetch(key.url);
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _UaNetworkImage && other.url == url;

  @override
  int get hashCode => url.hashCode;

  @override
  String toString() => '_UaNetworkImage("$url", scale: $scale)';
}

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

/// 一张图的多级候选地址(按顺序尝试, 前一个失败就换下一个):
/// 1. https + 缩略图  2. https 原图  3. http 原图
/// 网易云 CDN 偶发对某个 host/尺寸回 403 或空 body(换尺寸/协议通常就好),
/// 单 URL 只试一次会让整屏图片变占位符, 所以这里逐级降级。
List<String> imageCandidates(String? url, {num? width, num? height}) {
  final src = httpsImageUrl(url);
  if (src.isEmpty) return const [];
  final raw = url!.trim();
  final out = <String>[];
  void add(String u) {
    if (u.isNotEmpty && !out.contains(u)) out.add(u);
  }

  add(neteaseThumbUrl(src, width: width, height: height));
  add(src);
  add(raw);
  if (raw.startsWith('https://')) add(raw.replaceFirst('https://', 'http://'));
  return out;
}

/// 带降级的网络图片: 候选依次尝试, 全失败才显示占位.
class _FallbackImage extends StatefulWidget {
  const _FallbackImage({
    required this.candidates,
    required this.placeholder,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final List<String> candidates;
  final Widget placeholder;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  State<_FallbackImage> createState() => _FallbackImageState();
}

class _FallbackImageState extends State<_FallbackImage> {
  int _index = 0;

  /// 会话级记忆:
  /// - `_resolved`: 这组候选里哪个 url 确认能出图(重建时直接用它, 不再从头试错)
  /// - `_dead`: 确认拿不到的 url(403/空 body), 之后直接跳过, 免得每次都重试一遍
  ///   从而在占位符和图片之间来回闪
  static final Map<String, String> _resolved = <String, String>{};
  static final Set<String> _dead = <String>{};

  static String _cacheKey(List<String> candidates) => candidates.join('\u0000');

  @override
  void didUpdateWidget(covariant _FallbackImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // url 换了(列表复用)就从头再来
    if (!_sameList(oldWidget.candidates, widget.candidates)) _index = 0;
  }

  /// 从 `_index` 开始挑第一个候选:
  /// 上次成功过的那个优先, 已知失败的(403/空 body)直接跳过.
  /// 返回 null 表示这组候选都试过了 → 显示占位符, 不再反复重试.
  int? _pickCandidate() {
    final all = widget.candidates;
    final known = _resolved[_cacheKey(all)];
    final knownIdx = known == null ? -1 : all.indexOf(known);
    if (knownIdx >= 0 && knownIdx >= _index && !_dead.contains(known)) {
      return knownIdx;
    }
    for (var i = _index; i < all.length; i++) {
      if (!_dead.contains(all[i])) return i;
    }
    return null;
  }

  void _markOk(String url) {
    final key = _cacheKey(widget.candidates);
    if (_resolved[key] == url) return;
    _resolved[key] = url;
  }

  /// 这个 url 拿不到: 拉黑 + 忘掉"它上次成功过", 然后试下一个
  void _markDead(String url, int idx) {
    if (_dead.length > 512) _dead.clear();
    _dead.add(url);
    final key = _cacheKey(widget.candidates);
    if (_resolved[key] == url) _resolved.remove(key);
    _nextFrom(idx);
  }

  static bool _sameList(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _nextFrom(int idx) {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _index = idx + 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.candidates.isEmpty) return widget.placeholder;
    final idx = _pickCandidate();
    if (idx == null) return widget.placeholder;
    final url = widget.candidates[idx];
    return Image(
      image: _UaNetworkImage(url),
      key: ValueKey('$url#$idx'),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      // 同一 State 换了 url 时保留上一帧, 不留白(不闪)
      gaplessPlayback: true,
      errorBuilder: (_, error, _) {
        // 临时诊断: 打开 IMG_DEBUG 看具体失败原因
        debugPrint('IMGFAIL idx=$idx url=$url error=$error');
        _markDead(url, idx);
        return widget.placeholder;
      },
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame != null) _markOk(url);
        return child;
      },
      loadingBuilder: (context, child, progress) =>
          progress == null ? child : widget.placeholder,
    );
  }
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
    final candidates = imageCandidates(url, width: width, height: height);
    if (candidates.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: _FallbackImage(
        candidates: candidates,
        placeholder: fallback,
        width: width,
        height: height,
        fit: fit,
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
    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, shape: BoxShape.circle),
      child: Icon(icon, size: size * 0.5, color: scheme.outline),
    );
    final candidates = imageCandidates(url, width: size, height: size);
    if (candidates.isEmpty) return fallback;
    return ClipOval(
      child: _FallbackImage(
        candidates: candidates,
        placeholder: fallback,
        width: size,
        height: size,
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
            child: _FallbackImage(
              candidates: imageCandidates(images[i]),
              placeholder: const Icon(Icons.broken_image, color: Colors.white54, size: 48),
              fit: BoxFit.contain,
            ),
          ),
        ),
      ),
    ),
  );
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
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Icon(Icons.music_note, size: size * 0.5, color: scheme.outline),
    );
    final candidates = imageCandidates(url, width: size, height: size);
    if (candidates.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: _FallbackImage(
        candidates: candidates,
        placeholder: placeholder,
        width: size,
        height: size,
      ),
    );
  }
}
