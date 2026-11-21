import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/theme.dart';

/// 记录 Slider **实际绘制**的 thumb 中心(见 [SliderComponentShape.paint] 的
/// center), 用它来量「落点」—— 不自己复刻 Material 的 thumb 定位公式, 否则
/// 测试只是在验证同一份猜测。preferredSize 与圆 thumb 口径一致(20x20), 换掉
/// 形状本身不改变端内缩(overlay 半径 24 更大, 见 layout.dart)。
class _ThumbProbe extends SliderComponentShape {
  Offset? center;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(20, 20);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    this.center = center;
    context.canvas.drawCircle(
      center,
      10,
      Paint()..color = const Color(0xFFFF0000),
    );
  }
}

/// 把设置页塞进指定视口/字号, 返回 probe。
Future<_ThumbProbe> _pumpSettings(
  WidgetTester tester, {
  Size size = const Size(360, 1200),
  double textScale = 1.25,
}) async {
  final probe = _ThumbProbe();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildLightTheme(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        // 外层 SliderTheme 只提供「记录落点」的 thumbShape; 字号滑块自己只固定
        // track/overlay, 不动 thumbShape, 所以它会生效。
        child: SliderTheme(
          data: SliderThemeData(thumbShape: probe),
          child: const Scaffold(body: AppearanceSettingsPage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byType(Slider));
  await tester.pumpAndSettle();
  return probe;
}

/// thumb 中心到 Slider 盒左边缘的距离(dp)。
///
/// probe 记下的是 Slider 自己绘制坐标系里的坐标(CompositedTransformTarget 的
/// LeaderLayer 以 Slider 盒左上角为原点; 视口滚动/RepaintBoundary 的平移都在
/// 这层之外), 所以 local.dx 就是「距盒左边缘」。这个假设由测试里的
/// 「min/max 两端到各自盒边缘距离相等」自检兜住。
double _thumbBoxX(_ThumbProbe probe) {
  final local = probe.center;
  expect(local, isNotNull, reason: 'Slider 没有绘制 thumb(probe 没被调用)');
  return local!.dx;
}

Future<void> _setScale(WidgetTester tester, double value) async {
  await AppSettings.instance.update(textScale: value);
  await tester.pumpAndSettle();
}

List<double> _divisions() {
  final values = <double>[];
  for (var i = 0; i <= AppSettings.textScaleDivisions; i++) {
    values.add(
      AppSettings.snapTextScale(
        AppSettings.kTextScaleMin + i * AppSettings.kTextScaleStep,
      ),
    );
  }
  return values;
}

void main() {
  final settings = AppSettings.instance;
  final before = settings.textScale;
  tearDown(() => settings.update(textScale: before));

  // 用户 2026-11-18 报障: 「滑块落点与档位标注点不对齐」。修前实测(360dp +
  // 1.25 字号, 同一套 probe 口径): min 偏差 33.70dp / max 偏差 36.08dp。
  // 修后对所有字号恒为 0.00dp —— 标签盒宽度由 layout.dart 的常量算出, 与
  // 文本自身宽度无关, 所以字号变化不会把标签中心带走。
  testWidgets('极端落点与两端 A 标签中心共线(多宽度 x 多字号)', (tester) async {
    for (final textScale in <double>[1.0, 1.25, 1.625]) {
      for (final width in <double>[300, 360]) {
        final probe = await _pumpSettings(
          tester,
          size: Size(width, 1200),
          textScale: textScale,
        );
        final sliderRect = tester.getRect(find.byType(Slider));
        final labels = find.text('A');
        expect(labels, findsNWidgets(2), reason: '滑块两端各一个 A');
        final leftLabelX = tester.getCenter(labels.at(0)).dx - sliderRect.left;
        final rightLabelX = tester.getCenter(labels.at(1)).dx - sliderRect.left;

        await _setScale(tester, AppSettings.kTextScaleMin);
        final minX = _thumbBoxX(probe);
        await _setScale(tester, AppSettings.kTextScaleMax);
        final maxX = _thumbBoxX(probe);

        debugPrint(
          'MEASURE ${width.toInt()}dp x$textScale: '
          'minThumb=${minX.toStringAsFixed(2)} leftLabel=${leftLabelX.toStringAsFixed(2)} '
          'dev=${(minX - leftLabelX).toStringAsFixed(2)} | '
          'maxThumb=${maxX.toStringAsFixed(2)} rightLabel=${rightLabelX.toStringAsFixed(2)} '
          'dev=${(rightLabelX - maxX).toStringAsFixed(2)}',
        );

        // 坐标系假设自检: min/max 到各自盒边缘的距离应相等
        expect(
          minX,
          moreOrLessEquals(sliderRect.width - maxX, epsilon: 0.5),
          reason: 'probe 坐标应相对 Slider 盒左边(两端对称)',
        );
        expect(
          (minX - leftLabelX).abs(),
          lessThanOrEqualTo(1.5),
          reason: '${width}dp x$textScale: value=min 时落点应落在左 A 的中心上',
        );
        expect(
          (rightLabelX - maxX).abs(),
          lessThanOrEqualTo(1.5),
          reason: '${width}dp x$textScale: value=max 时落点应落在右 A 的中心上',
        );
      }
    }
  });

  testWidgets('相邻格子的落点间距相等(snap 值与刻度一致)', (tester) async {
    final probe = await _pumpSettings(tester);
    final xs = <double>[];
    final values = _divisions();
    for (final v in values) {
      await _setScale(tester, v);
      expect(settings.textScale, moreOrLessEquals(v, epsilon: 0.001));
      xs.add(_thumbBoxX(probe));
    }
    final gaps = <double>[];
    for (var i = 1; i < xs.length; i++) {
      gaps.add(xs[i] - xs[i - 1]);
    }
    debugPrint(
      'MEASURE gaps: ${gaps.map((g) => g.toStringAsFixed(3)).toList()}',
    );
    final mean = gaps.reduce((a, b) => a + b) / gaps.length;
    for (var i = 0; i < gaps.length; i++) {
      expect(
        gaps[i],
        moreOrLessEquals(mean, epsilon: 0.5),
        reason:
            '第 ${i + 1} 段(→${AppSettings.textScaleLabel(values[i + 1])})'
            '间距 ${gaps[i]} 偏离平均值 $mean',
      );
    }
    // 单调递增: 不会「拖到 1.05 却显示 1.10」
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i], greaterThan(xs[i - 1]));
    }
  });
}
