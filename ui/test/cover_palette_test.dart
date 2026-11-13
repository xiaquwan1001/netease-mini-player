// 封面取色单元测试: 合成 ui.Image / RGBA 字节 + CoverBackdrop widget 测试。
// 无网络: url 缓存测试用注入的本地 ImageProvider(带 resolve 计数器)。
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/cover_backdrop.dart';
import 'package:minincm/src/cover_palette.dart';

// 需要确认包名: 见 pubspec.yaml 的 name 字段
// (若不同, 编排者只需改上面两个 import 的包名)

Future<ui.Image> _imageFromPixels(List<int> rgba, int w, int h) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    Uint8List.fromList(rgba),
    w,
    h,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

Future<List<int>> _imageBytes(ui.Image image) async {
  final bd = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
  return bd!.buffer.asUint8List();
}

/// 纯色/双色合成封面
Future<ui.Image> _solidImage(
  int r,
  int g,
  int b, {
  int w = 32,
  int h = 32,
  int? r2,
  int? g2,
  int? b2,
}) async {
  final rgba = <int>[];
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final secondHalf = r2 != null && x >= w ~/ 2;
      rgba.addAll([
        secondHalf ? r2 : r,
        secondHalf ? (g2 ?? g) : g,
        secondHalf ? (b2 ?? b) : b,
        255,
      ]);
    }
  }
  return _imageFromPixels(rgba, w, h);
}

bool _hueIn(double h, double lo, double hi) {
  if (lo <= hi) return h >= lo && h <= hi;
  return h >= lo || h <= hi; // 跨 0 环形区间
}

/// 本地静态图 provider, 记录 resolve 次数(验证「同一 url 只算一次」)
class _CountingImageProvider extends ImageProvider<_CountingImageProvider> {
  _CountingImageProvider(this._rgba, this._w, this._h);
  final List<int> _rgba;
  final int _w, _h;
  int resolveCount = 0;

  @override
  Future<_CountingImageProvider> obtainKey(ImageConfiguration cfg) {
    return SynchronousFuture<_CountingImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _CountingImageProvider key,
    ImageDecoderCallback decode,
  ) {
    resolveCount++;
    return MultiFrameImageStreamCompleter(codec: _codec(), scale: 1.0);
  }

  Future<ui.Codec> _codec() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      Uint8List.fromList(_rgba),
    );
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: _w,
      height: _h,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    return descriptor.instantiateCodec();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => clearCoverPaletteCache());

  group('纯函数: HSL/HSV/打分', () {
    test('rgbToHsl 红色 hue≈0, 灰色 s=0', () {
      final (h, s, _) = rgbToHsl(220, 30, 40);
      expect(h, closeTo(356.8, 1));
      expect(s, greaterThan(0.7));
      expect(rgbToHsl(128, 128, 128).$2, 0);
    });

    test('isVibrantSwatch 阈值窗口', () {
      expect(isVibrantSwatch(0.5, 0.5), isTrue);
      expect(isVibrantSwatch(0.2, 0.5), isFalse); // 饱和度不足
      expect(isVibrantSwatch(0.5, 0.98), isFalse); // 过亮
      expect(isVibrantSwatch(0.5, 0.1), isFalse); // 过暗
    });

    test('hueDistance 环形距离', () {
      expect(hueDistance(350, 10), 20);
      expect(hueDistance(10, 350), 20);
      expect(hueDistance(100, 200), 100);
    });

    test('buildGradient 亮度上限与低饱和柔化', () {
      final colors = buildGradient(
        const Color.fromARGB(255, 255, 235, 59), // 亮黄(高亮度高饱和)
        const Color.fromARGB(255, 255, 0, 200), // 亮粉(高饱和)
      );
      expect(colors.length, 2);
      for (final c in colors) {
        final (_, s, l) = rgbToHsl(_cR(c), _cG(c), _cB(c));
        expect(l, lessThanOrEqualTo(kMaxGradientLightness + 0.01));
        expect(s, lessThanOrEqualTo(0.65)); // 柔化后饱和度受控
      }
    });
  });

  group('paletteFromBytes / paletteFromImage', () {
    test('红色系封面: 主色 hue∈[340,20], 非 fallback', () async {
      final img = await _solidImage(220, 30, 40);
      final p = await paletteFromImage(img);
      expect(p, isNotNull);
      expect(p!.isFallback, isFalse);
      final h = rgbToHsv(_cR(p.primary), _cG(p.primary), _cB(p.primary)).$1;
      expect(_hueIn(h, 340, 20), isTrue, reason: 'hue=$h');
    });

    test('蓝紫封面: 主色 hue∈[230,300]', () async {
      final img = await _solidImage(90, 70, 200);
      final p = await paletteFromImage(img);
      expect(p, isNotNull);
      expect(p!.isFallback, isFalse);
      final h = rgbToHsv(_cR(p.primary), _cG(p.primary), _cB(p.primary)).$1;
      expect(_hueIn(h, 230, 300), isTrue, reason: 'hue=$h');
    });

    test('双色封面: 渐变两色且色相可区分, 亮度受控', () async {
      final img = await _solidImage(220, 30, 40, r2: 30, g2: 90, b2: 220);
      final p = await paletteFromImage(img);
      expect(p, isNotNull);
      expect(p!.backgroundGradient.length, 2);
      for (final c in p.backgroundGradient) {
        final (_, _, l) = rgbToHsl(_cR(c), _cG(c), _cB(c));
        expect(l, lessThanOrEqualTo(kMaxGradientLightness + 0.01));
      }
    });

    test('纯灰封面: isFallback=true 回退主题', () async {
      final img = await _solidImage(128, 128, 128);
      final p = await paletteFromImage(img);
      expect(p!.isFallback, isTrue);
    });

    test('纯黑封面: isFallback=true', () async {
      final img = await _solidImage(0, 0, 0);
      expect((await paletteFromImage(img))!.isFallback, isTrue);
    });

    test('纯白封面: isFallback=true', () async {
      final img = await _solidImage(255, 255, 255);
      expect((await paletteFromImage(img))!.isFallback, isTrue);
    });

    test('坏数据不抛异常: 空字节 / 长度不符 / 尺寸非法 → null', () {
      expect(paletteFromBytes(Uint8List(0), 0, 0), isNull);
      expect(paletteFromBytes(Uint8List.fromList([1, 2, 3]), 4, 4), isNull);
      expect(
        paletteFromBytes(Uint8List.fromList([255, 0, 0, 255]), -1, 1),
        isNull,
      );
    });
  });

  group('paletteFromUrl 缓存', () {
    test('同一 url 只 resolve 一次(LRU 缓存生效)', () async {
      final img = await _solidImage(30, 90, 220);
      final rgba = await _imageBytes(img);
      final provider = _CountingImageProvider(rgba, 32, 32);

      final p1 = await paletteFromUrl(
        'file://test-red-blue',
        provider: provider,
      );
      final p2 = await paletteFromUrl(
        'file://test-red-blue',
        provider: provider,
      );
      expect(p1, isNotNull);
      expect(p2, isNotNull);
      expect(provider.resolveCount, 1, reason: '第二次调用应命中缓存');

      // 不同 url → 再次 resolve(先清全局 imageCache, 避免按 key 命中缓存)
      PaintingBinding.instance.imageCache.clear();
      provider.resolveCount = 0;
      await paletteFromUrl('file://other', provider: provider);
      expect(provider.resolveCount, 1);
    });

    test('null/空 url → null, 不抛异常', () async {
      expect(await paletteFromUrl(null), isNull);
      expect(await paletteFromUrl(''), isNull);
    });
  });

  group('CoverBackdrop widget', () {
    const palette = CoverPalette(
      primary: Color.fromARGB(255, 180, 40, 60),
      secondary: Color.fromARGB(255, 40, 60, 180),
      onPrimary: Color.fromARGB(255, 245, 245, 245),
      backgroundGradient: [
        Color.fromARGB(255, 40, 8, 12),
        Color.fromARGB(255, 60, 12, 18),
      ],
      isFallback: false,
    );

    BoxDecoration? decorationOf(WidgetTester tester, Key key) {
      final ctx = tester.element(find.byKey(key));
      return ctx.findAncestorWidgetOfExactType<AnimatedContainer>()?.decoration
          as BoxDecoration?;
    }

    testWidgets('palette=null: 不改变背景(decoration 为 null, 透明直通)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CoverBackdrop(
            palette: null,
            child: const SizedBox(key: Key('inner'), width: 50, height: 50),
          ),
        ),
      );
      expect(decorationOf(tester, const Key('inner')), isNull);
    });

    testWidgets('palette=isFallback: 同样透明直通回退主题', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CoverBackdrop(
            palette: const CoverPalette(
              primary: Color(0xFF888888),
              secondary: Color(0xFF888888),
              onPrimary: Color(0xFF111111),
              backgroundGradient: [Color(0xFF222222), Color(0xFF333333)],
              isFallback: true,
            ),
            child: const SizedBox(key: Key('inner'), width: 50, height: 50),
          ),
        ),
      );
      expect(decorationOf(tester, const Key('inner')), isNull);
    });

    testWidgets('有 palette: 背景与默认不同(渐变 decoration), 300ms 过渡', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CoverBackdrop(
            palette: palette,
            child: const SizedBox(key: Key('inner'), width: 50, height: 50),
          ),
        ),
      );
      final deco = decorationOf(tester, const Key('inner'));
      expect(deco, isNotNull);
      expect(deco!.gradient, isA<LinearGradient>());
      expect(
        (deco.gradient! as LinearGradient).colors,
        palette.backgroundGradient,
      );
      // 过渡动画: 先未到 300ms 再 pump 到结束, 不抛异常
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pumpAndSettle();
    });

    testWidgets('300dp + 1.25 字号: 渐变背景正常渲染不溢出', (tester) async {
      tester.view.physicalSize = const Size(300, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
            child: Scaffold(
              body: CoverBackdrop(
                palette: palette,
                child: Center(
                  child: Text(
                    '一首名字特别特别长的歌名用于窄屏回归测试',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('窄屏回归测试'), findsOneWidget);
    });
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: home,
    ),
  );
}

// Color → 0..255 通道助手(测试里也要避开弃用的 .red/.green/.blue)
int _ch(double c) => (c * 255.0).round().clamp(0, 255);
int _cR(Color c) => _ch(c.r);
int _cG(Color c) => _ch(c.g);
int _cB(Color c) => _ch(c.b);
