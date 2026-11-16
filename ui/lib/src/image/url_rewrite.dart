import 'package:flutter/widgets.dart';

import '../app_settings.dart';

/// 网易云封面/图片直链常是明文 http; CDN 同路径支持 https(证书覆盖 *.music.126.net)。
/// Android 边拉边播/图片加载统一升级到 https, 避免明文 80 被中间设备拦成空 body。
String httpsImageUrl(String? url) {
  if (url == null || url.isEmpty) return '';
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return url;
  return uri.replace(scheme: 'https').toString();
}

/// 按「显示尺寸 x 设备像素比 x 用户档位」算要向 CDN 请求的像素边长.
///
/// 之前直接用逻辑尺寸当像素数(44dp 的封面就要 44px 的图), 在高 DPR 的手机上被放大
/// 2~3 倍显示 ⇒ 肉眼可见的糊。现在按真实像素取, 默认档位([CoverQuality.standard])
/// 就是"屏幕 1:1", 用户可以在设置里换省流/超清。
///
/// 下限 60(再小 CDN 出来就是糊块), 上限 1600(网易最大原图档, 再大没有意义).
double coverRequestPx(
  BuildContext context,
  double logicalSize, {
  CoverQuality? quality,
}) {
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  final mult = (quality ?? AppSettings.instance.coverQuality).multiplier;
  final px = logicalSize * dpr * mult;
  if (!px.isFinite) return 0;
  return px.clamp(60, 1600).roundToDouble();
}

/// 按**真实像素矩形**请求: 输出 `?param=WxH`(不是 [neteaseThumbUrl] 的方图).
///
/// 背景横幅是"宽而矮"的矩形(如 1080x510), 而 [neteaseThumbUrl] 取 max(w,h) 做方图,
/// 于是 `height=170` 的横幅只能拿到 `param=170y170` —— 一张 ~170px 的方图被放大
/// 6 倍铺满整屏, 糊到看不清。这里把宽高分别写进 param, 让 CDN 按矩形裁.
///
/// 非有限/非正的边长会被忽略; 两边都无效时原样返回(不加 param).
String neteaseSizedUrl(String url, {num? widthPx, num? heightPx}) {
  if (url.isEmpty) return url;
  final w = (widthPx != null && widthPx.isFinite && widthPx > 0)
      ? widthPx.round()
      : 0;
  final h = (heightPx != null && heightPx.isFinite && heightPx > 0)
      ? heightPx.round()
      : 0;
  if (w <= 0 && h <= 0) return url;
  // 单边有效时就按正方形补另一条边(CDN 不接受 0)
  final pw = w > 0 ? w : h;
  final ph = h > 0 ? h : w;
  final sep = url.contains('?') ? '&' : '?';
  return '$url${sep}param=${pw}y$ph';
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

/// 背景横幅/大图要按"显示区域 x DPR x 档位"取图, 而不是按逻辑尺寸当像素数.
///
/// 与 [coverRequestPx] 同一套档位算子, 区别只在:
/// - 返回**矩形**(宽高分别算), 宽高比跟控件一致;
/// - 上限 1080: 背景图铺满屏宽, CDN 再大也没意义(手机屏物理宽通常 < 1080).
({int widthPx, int heightPx}) bannerRequestPx(
  BuildContext context, {
  required double logicalWidth,
  required double logicalHeight,
  CoverQuality? quality,
  double maxPx = 1080,
}) {
  final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
  final mult = (quality ?? AppSettings.instance.coverQuality).multiplier;
  var w = logicalWidth.isFinite ? logicalWidth * dpr * mult : 0.0;
  var h = logicalHeight.isFinite ? logicalHeight * dpr * mult : 0.0;
  if (w <= 0 || h <= 0) return (widthPx: 0, heightPx: 0);
  // 等比缩到上限内, 别为了压宽把高拉成方图
  if (w > maxPx) {
    final k = maxPx / w;
    w = maxPx;
    h *= k;
  }
  if (h > maxPx) {
    final k = maxPx / h;
    h = maxPx;
    w *= k;
  }
  return (widthPx: w.round(), heightPx: h.round());
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

/// 按**像素矩形**取图的多级候选(给背景横幅用): 1. https + `param=WxH`
/// 2. https 原图 3. http 原图 —— 降级链与 [imageCandidates] 一致, 只是第一级
/// 从"方图缩略"换成了"矩形缩略".
List<String> sizedImageCandidates(
  String? url, {
  required int widthPx,
  required int heightPx,
}) {
  final src = httpsImageUrl(url);
  if (src.isEmpty) return const [];
  if (widthPx <= 0 || heightPx <= 0) {
    return imageCandidates(url, width: widthPx, height: heightPx);
  }
  final raw = url!.trim();
  final out = <String>[];
  void add(String u) {
    if (u.isNotEmpty && !out.contains(u)) out.add(u);
  }

  add(neteaseSizedUrl(src, widthPx: widthPx, heightPx: heightPx));
  add(src);
  add(raw);
  if (raw.startsWith('https://')) add(raw.replaceFirst('https://', 'http://'));
  return out;
}
