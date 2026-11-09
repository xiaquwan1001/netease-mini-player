/// 封面取色(node-vibrant 思路, 纯 Dart 实现, 无新依赖)。
///
/// 流程: 图片降采样到 ≤64x64 → 5-bit/通道 直方图聚类 → 按 node-vibrant 口径
/// 打分选主色(Vibrant 优先, 其次 DarkVibrant/Muted, 最后最高频色)。
/// 纯灰/纯黑/纯白封面(饱和度 < 0.15)返回 isFallback=true, 调用方回退主题色。
///
/// 【之后如何接到歌曲详情页(歌词页)】编排者接线说明:
/// 歌曲详情页(State)里保存 `CoverPalette? _palette;`, 在拿到当前曲目后:
///   _palette = await paletteFromUrl(track.coverUrl);
///   if (mounted) setState(() {});
/// 然后用 `CoverBackdrop(palette: _palette, child: ...)` 包住歌词页背景容器
/// (或 Scaffold body 的最外层)。切换/长按换曲时对新的 coverUrl 重算一次即可,
/// 同一 url 有 LRU 缓存, 重复调用不会重复计算; palette 为 null 时
/// CoverBackdrop 完全透明直通, 不影响现有主题。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// 量化位数: 5-bit/通道 → 最多 32768 个桶
const int kQuantBits = 5;

/// Vibrant 判定阈值(node-vibrant 口径)
const double kVibrantMinSaturation = 0.35;
const double kVibrantMinValue = 0.25;
const double kVibrantMaxValue = 0.95;

/// 低于该饱和度视为「无彩」(灰/黑/白封面) → 回退主题
const double kFallbackMaxSaturation = 0.15;

/// 深色主题下渐变颜色的亮度上限(避免刺眼)
const double kMaxGradientLightness = 0.35;

/// 背景混合比例: primary 混入深色底的上限 ~18%
const double kBackdropPrimaryMix = 0.18;

/// LRU 缓存上限
const int kPaletteCacheMax = 32;

// Flutter 3.27+ 的 Color 用 double 通道, 统一转回 0..255 整数便于 HSL 计算
int _ch(double channel) => (channel * 255.0).round().clamp(0, 255);
int _r(Color c) => _ch(c.r);
int _g(Color c) => _ch(c.g);
int _b(Color c) => _ch(c.b);

// ---------------------------------------------------------------- HSL/HSV

/// RGB(0..255) → HSL, h∈[0,360), s/l∈[0,1]
(double h, double s, double l) rgbToHsl(int r, int g, int b) {
  final rf = r / 255, gf = g / 255, bf = b / 255;
  final max = math.max(rf, math.max(gf, bf));
  final min = math.min(rf, math.min(gf, bf));
  final l = (max + min) / 2;
  if (max == min) return (0, 0, l);
  final d = max - min;
  final s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  double h;
  if (max == rf) {
    h = (gf - bf) / d + (gf < bf ? 6 : 0);
  } else if (max == gf) {
    h = (bf - rf) / d + 2;
  } else {
    h = (rf - gf) / d + 4;
  }
  return (h * 60, s, l);
}

/// RGB(0..255) → HSV, h∈[0,360), s/v∈[0,1]
(double h, double s, double v) rgbToHsv(int r, int g, int b) {
  final rf = r / 255, gf = g / 255, bf = b / 255;
  final max = math.max(rf, math.max(gf, bf));
  final min = math.min(rf, math.min(gf, bf));
  final d = max - min;
  if (d == 0) return (0, 0, max);
  double h;
  if (max == rf) {
    h = (gf - bf) / d + (gf < bf ? 6 : 0);
  } else if (max == gf) {
    h = (bf - rf) / d + 2;
  } else {
    h = (rf - gf) / d + 4;
  }
  return (h * 60, d / max, max);
}

/// 是否满足 Vibrant 的饱和度/亮度窗口(纯函数, 便于单测)
bool isVibrantSwatch(double saturation, double value) {
  return saturation >= kVibrantMinSaturation &&
      value >= kVibrantMinValue &&
      value <= kVibrantMaxValue;
}

/// node-vibrant 式打分: population 占比 × (饱和度接近度 × 0.6 + 亮度接近度 × 0.4)
/// 亮度峰值在 0.5, 过暗/过亮都降分。纯函数。
double swatchScore({
  required int population,
  required int maxPopulation,
  required double saturation,
  required double value,
}) {
  if (maxPopulation <= 0) return 0;
  if (saturation < kFallbackMaxSaturation * 0.5 || value < 0.08) return 0;
  final popScore = population / maxPopulation;
  final sat = (saturation / kVibrantMinSaturation).clamp(0.0, 1.0);
  final lum = (1.0 - (value - 0.5).abs() / 0.5).clamp(0.0, 1.0);
  return popScore * (sat * 0.6 + lum * 0.4);
}

/// hue 环形距离(0..180), 便于单测
double hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

// ---------------------------------------------------------------- palette

/// 取色结果。isFallback=true 时调用方应回退主题色(不要用这里的颜色做背景)。
@immutable
class CoverPalette {
  const CoverPalette({
    required this.primary,
    required this.secondary,
    required this.onPrimary,
    required this.backgroundGradient,
    required this.isFallback,
  });

  final Color primary;
  final Color secondary;
  final Color onPrimary;
  final List<Color> backgroundGradient;
  final bool isFallback;

  @override
  bool operator ==(Object other) =>
      other is CoverPalette &&
      other.primary == primary &&
      other.secondary == secondary &&
      other.isFallback == isFallback;

  @override
  int get hashCode => Object.hash(primary, secondary, isFallback);
}

/// 一个颜色聚类桶(量化后的平均色 + 像素占比)
@immutable
class PaletteSwatch {
  const PaletteSwatch(this.color, this.population);
  final Color color;
  final int population;
}

/// 从聚类桶里按 node-vibrant 口径选主色: Vibrant > DarkVibrant/Muted > 最高频。
/// 纯函数, 便于单测。
Color? selectPrimary(List<PaletteSwatch> swatches) {
  if (swatches.isEmpty) return null;
  final maxPop = swatches
      .map((s) => s.population)
      .reduce(math.max);

  double scoreOf(PaletteSwatch s) => swatchScore(
        population: s.population,
        maxPopulation: maxPop,
        saturation: rgbToHsv(_r(s.color), _g(s.color), _b(s.color)).$2,
        value: rgbToHsv(_r(s.color), _g(s.color), _b(s.color)).$3,
      );

  PaletteSwatch? best;
  double bestScore = -1;
  for (final s in swatches) {
    final hsv = rgbToHsv(_r(s.color), _g(s.color), _b(s.color));
    if (!isVibrantSwatch(hsv.$2, hsv.$3)) continue;
    final score = scoreOf(s);
    if (score > bestScore) {
      bestScore = score;
      best = s;
    }
  }
  // 回退 1: 暗彩/柔和(放宽亮度, 保留饱和度下限)
  best ??= _bestWhere(
      swatches,
      (s) => rgbToHsv(_r(s.color), _g(s.color), _b(s.color)).$2 >=
          kFallbackMaxSaturation);
  // 回退 2: 任意最高频色
  best ??= swatches.reduce((a, b) => a.population >= b.population ? a : b);
  return best.color;
}

PaletteSwatch? _bestWhere(
    List<PaletteSwatch> swatches, bool Function(PaletteSwatch) test) {
  PaletteSwatch? best;
  double bestScore = -1;
  final maxPop = swatches.isEmpty
      ? 0
      : swatches.map((s) => s.population).reduce(math.max);
  for (final s in swatches) {
    if (!test(s)) continue;
    final hsv = rgbToHsv(_r(s.color), _g(s.color), _b(s.color));
    final score = swatchScore(
      population: s.population,
      maxPopulation: maxPop,
      saturation: hsv.$2,
      value: hsv.$3,
    );
    if (score > bestScore) {
      bestScore = score;
      best = s;
    }
  }
  return best;
}

/// 生成深色友好的背景渐变: primary 最多以 [kBackdropPrimaryMix] 比例参与,
/// 每个颜色亮度都被压到 [maxLightness] 以下。纯函数。
List<Color> buildGradient(
  Color primary,
  Color secondary, {
  double maxLightness = kMaxGradientLightness,
  double primaryMix = kBackdropPrimaryMix,
}) {
  Color soften(Color c) {
    final (h, s, l) = rgbToHsl(_r(c), _g(c), _b(c));
    final s2 = s > 0.6 ? 0.6 : s; // 柔化: 低饱和
    final l2 = math.min(l, maxLightness);
    return _hslToColor(h, s2 * primaryMix + 0.02, l2);
  }

  return [soften(primary), soften(secondary)];
}

Color _hslToColor(double h, double s, double l) {
  double rf, gf, bf;
  if (s == 0) {
    rf = gf = bf = l;
  } else {
    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    rf = _hueToRgb(p, q, h + 120);
    gf = _hueToRgb(p, q, h);
    bf = _hueToRgb(p, q, h - 120);
  }
  return Color.fromARGB(
      255, (rf * 255).round().clamp(0, 255), (gf * 255).round().clamp(0, 255), (bf * 255).round().clamp(0, 255));
}

double _hueToRgb(double p, double q, double t) {
  var tt = t % 360 / 360;
  if (tt < 0) tt += 1;
  if (tt < 1 / 6) return p + (q - p) * 6 * tt;
  if (tt < 1 / 2) return q;
  if (tt < 2 / 3) return p + (q - p) * (2 / 3 - tt) * 6;
  return p;
}

Color _onPrimaryFor(Color c) {
  final lum = 0.299 * c.r * 255 + 0.587 * c.g * 255 + 0.114 * c.b * 255;
  return lum > 140 ? const Color(0xFF101010) : const Color(0xFFF5F5F5);
}

// ---------------------------------------------------------------- bytes → palette

/// 从 RGBA 字节取色(量化 + 选色), 坏数据返回 null 不抛异常。
CoverPalette? paletteFromBytes(Uint8List rgba, int width, int height) {
  try {
    if (width <= 0 || height <= 0) return null;
    if (rgba.length < width * height * 4) return null;

    // 降采样: 每边最多 ~64 个采样点
    final step = math.max(1, (math.max(width, height) / 64).ceil());
    final buckets = HashMap<int, List<int>>(); // key -> [rSum,gSum,bSum,count]
    for (var y = 0; y < height; y += step) {
      for (var x = 0; x < width; x += step) {
        final i = (y * width + x) * 4;
        if (rgba[i + 3] < 128) continue;
        final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
        final key = (r >> (8 - kQuantBits)) << (kQuantBits * 2) |
            (g >> (8 - kQuantBits)) << kQuantBits |
            (b >> (8 - kQuantBits));
        final acc = buckets.putIfAbsent(key, () => [0, 0, 0, 0]);
        acc[0] += r;
        acc[1] += g;
        acc[2] += b;
        acc[3]++;
      }
    }
    if (buckets.isEmpty) return null;

    final swatches = buckets.values
        .map((acc) => PaletteSwatch(
              Color.fromARGB(255, acc[0] ~/ acc[3], acc[1] ~/ acc[3],
                  acc[2] ~/ acc[3]),
              acc[3],
            ))
        .toList();

    final primary = selectPrimary(swatches);
    if (primary == null) return null;

    final primaryHsv =
        rgbToHsv(_r(primary), _g(primary), _b(primary));
    final isFallback = primaryHsv.$2 < kFallbackMaxSaturation;

    // secondary: 与 primary 色相距离最大的高分桶
    PaletteSwatch? sec;
    double bestHueDist = -1;
    for (final s in swatches) {
      if (s.color == primary) continue;
      final hsv = rgbToHsv(_r(s.color), _g(s.color), _b(s.color));
      if (hsv.$2 < kFallbackMaxSaturation) continue;
      final d = hueDistance(hsv.$1, primaryHsv.$1);
      if (d > bestHueDist) {
        bestHueDist = d;
        sec = s;
      }
    }
    final secondary = sec?.color ?? primary;

    return CoverPalette(
      primary: primary,
      secondary: secondary,
      onPrimary: _onPrimaryFor(primary),
      backgroundGradient: buildGradient(primary, secondary),
      isFallback: isFallback,
    );
  } catch (_) {
    return null;
  }
}

/// 从已解码的 [ui.Image] 取色。失败返回 null(调用方回退主题色)。
///
/// 说明: 计算只发生在 ≤64x64 的降采样像素(≤4096 px)上, 主线程开销可忽略,
/// 因此没有引入 isolate/compute(纯 Dart 同步函数无法跨 isolate 传 ui.Image)。
Future<CoverPalette?> paletteFromImage(ui.Image image) async {
  try {
    final bd =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (bd == null) return null;
    return paletteFromBytes(
        bd.buffer.asUint8List(), image.width, image.height);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- url 解析 + LRU 缓存

final LinkedHashMap<String, Future<CoverPalette?>> _paletteCache =
    LinkedHashMap();

/// 清空调色缓存(测试用)
@visibleForTesting
void clearCoverPaletteCache() => _paletteCache.clear();

/// 按 url 取色, 带 LRU 缓存(上限 [kPaletteCacheMax]);
/// 同一 url 只 resolve/计算一次(缓存的是 Future, 并发调用也复用)。
/// 网络失败返回 null, 调用方回退主题色。
Future<CoverPalette?> paletteFromUrl(
  String? url, {
  ImageProvider<Object>? provider,
}) async {
  if (url == null || url.isEmpty) return null;
  final cached = _paletteCache.remove(url);
  if (cached != null) {
    _paletteCache[url] = cached; // 触碰 LRU
    return cached;
  }
  final future = _computeForUrl(url, provider ?? NetworkImage(url));
  _paletteCache[url] = future;
  while (_paletteCache.length > kPaletteCacheMax) {
    _paletteCache.remove(_paletteCache.keys.first);
  }
  return future;
}

Future<CoverPalette?> _computeForUrl(
    String url, ImageProvider<Object> provider) async {
  try {
    final image = await _resolveImage(provider);
    return await paletteFromImage(image);
  } catch (_) {
    return null;
  }
}

Future<ui.Image> _resolveImage(ImageProvider<Object> provider) {
  final completer = Completer<ui.Image>();
  final stream = provider.resolve(const ImageConfiguration(size: Size(64, 64)));
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) {
      if (!completer.isCompleted) {
        stream.removeListener(listener);
        completer.complete(info.image);
      }
    },
    onError: (Object error, StackTrace? stack) {
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  stream.addListener(listener);
  return completer.future;
}
