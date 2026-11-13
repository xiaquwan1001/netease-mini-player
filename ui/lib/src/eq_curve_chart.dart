// 自定义响度曲线(EQ)可视化/编辑: 频响曲线图 + 柱状图.
// 纯 Dart + Flutter painting, 无新依赖; 权威解析在 eq_profile.dart.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'eq_profile.dart';

/// 数字 biquad 求值使用的采样率(与 Rust 侧一致的物理上限推导).
const double eqEvalSampleRateHz = 48000.0;

// ---------------------------------------------------------------- 纯函数

/// RBJ biquad 幅频响应在 [freqHz] 处的增益(dB). 只支持 PK/LS/HS.
/// OFF filter 不参与(由调用方过滤).
double filterMagnitudeDb(EqFilter f, double freqHz) {
  final w0 = 2 * math.pi * f.freqHz / eqEvalSampleRateHz;
  final a = math.pow(10.0, f.gainDb / 40.0).toDouble();
  final cw = math.cos(w0);
  final sw = math.sin(w0);

  double b0, b1, b2, a0, a1, a2;
  switch (f.type) {
    case EqFilterType.pk:
      final alpha = sw / (2 * f.q);
      b0 = 1 + alpha * a;
      b1 = -2 * cw;
      b2 = 1 - alpha * a;
      a0 = 1 + alpha / a;
      a1 = -2 * cw;
      a2 = 1 - alpha / a;
    case EqFilterType.ls:
      final alpha = sw / 2 * math.sqrt((a + 1 / a) * 2);
      final twoSqrtAalpha = 2 * math.sqrt(a) * alpha;
      b0 = a * ((a + 1) - (a - 1) * cw + twoSqrtAalpha);
      b1 = 2 * a * ((a - 1) - (a + 1) * cw);
      b2 = a * ((a + 1) - (a - 1) * cw - twoSqrtAalpha);
      a0 = (a + 1) + (a - 1) * cw + twoSqrtAalpha;
      a1 = -2 * ((a - 1) + (a + 1) * cw);
      a2 = (a + 1) + (a - 1) * cw - twoSqrtAalpha;
    case EqFilterType.hs:
      final alpha = sw / 2 * math.sqrt((a + 1 / a) * 2);
      final twoSqrtAalpha = 2 * math.sqrt(a) * alpha;
      b0 = a * ((a + 1) + (a - 1) * cw + twoSqrtAalpha);
      b1 = -2 * a * ((a - 1) + (a + 1) * cw);
      b2 = a * ((a + 1) + (a - 1) * cw - twoSqrtAalpha);
      a0 = (a + 1) - (a - 1) * cw + twoSqrtAalpha;
      a1 = 2 * ((a - 1) - (a + 1) * cw);
      a2 = (a + 1) - (a - 1) * cw - twoSqrtAalpha;
  }

  double mag(double w) {
    final c1 = math.cos(w);
    final s1 = math.sin(w);
    final c2 = math.cos(2 * w);
    final s2 = math.sin(2 * w);
    final numB = b0 + b1 * c1 + b2 * c2;
    final numI = b1 * s1 + b2 * s2;
    final denB = a0 + a1 * c1 + a2 * c2;
    final denI = a1 * s1 + a2 * s2;
    final num = math.sqrt(numB * numB + numI * numI);
    final den = math.sqrt(denB * denB + denI * denI);
    return num / den;
  }

  final m = mag(2 * math.pi * freqHz / eqEvalSampleRateHz);
  if (m <= 0) return -maxEqGainDb;
  return 20 * math.log(m) / math.ln10;
}

/// 整条曲线(Preamp + 各 ON filter 级联)在给定频点列表上的 dB.
List<double> evaluateEqDb(ParametricEq eq, List<double> freqs) {
  final active = eq.filters.where((f) => f.enabled).toList(growable: false);
  return [
    for (final f0 in freqs)
      eq.preampDb +
          active.fold(0.0, (sum, f) => sum + filterMagnitudeDb(f, f0)),
  ];
}

/// 曲线图坐标映射: 对数频率 20Hz~20kHz, dB -24..+24.
/// 返回绘图坐标点(左下原点为 Flutter 常规 Offset).
List<Offset> computeCurve(
  ParametricEq eq,
  Size size, {
  int points = 160,
  double minFreqHz = 20,
  double maxFreqHz = 20000,
  double minDb = -24,
  double maxDb = 24,
}) {
  final freqs = <double>[
    for (var i = 0; i < points; i++)
      minFreqHz *
          math.pow(maxFreqHz / minFreqHz, i / (points - 1).clamp(1, 1 << 30)),
  ];
  final dbs = evaluateEqDb(eq, freqs);
  return [
    for (var i = 0; i < points; i++)
      Offset(
        eqCurveX(freqs[i], size.width, minFreqHz, maxFreqHz),
        eqCurveY(dbs[i], size.height, minDb, maxDb),
      ),
  ];
}

/// 对数频率 → x 像素.
double eqCurveX(
  double freqHz,
  double width, [
  double minFreqHz = 20,
  double maxFreqHz = 20000,
]) {
  final t = math.log(freqHz / minFreqHz) / math.log(maxFreqHz / minFreqHz);
  return t.clamp(0.0, 1.0) * width;
}

/// dB → y 像素(0dB 在中间).
double eqCurveY(
  double db,
  double height, [
  double minDb = -24,
  double maxDb = 24,
]) {
  final t = (maxDb - db.clamp(minDb, maxDb)) / (maxDb - minDb);
  return t * height;
}

/// 频点 → 显示文本(20 / 500 / 1k / 20k).
String eqFreqLabel(double freqHz) {
  if (freqHz >= 1000) {
    final k = freqHz / 1000;
    return k == k.roundToDouble()
        ? '${k.round()}k'
        : '${k.toStringAsFixed(1)}k';
  }
  return freqHz == freqHz.roundToDouble()
      ? freqHz.round().toString()
      : freqHz.toStringAsFixed(0);
}

/// 将 [filterIndex] 的 Gain 改为 [newGain](clamp ±24, 步进 0.1 由调用方保证),
/// 其余 filter(含顺序/ON-OFF/Preamp)不变, 按 AutoEQ 格式重新序列化.
String rewriteEqFilterGain(ParametricEq eq, int filterIndex, double newGain) {
  final gain = newGain.clamp(-maxEqGainDb, maxEqGainDb);
  final filters = [
    for (final f in eq.filters)
      if (f.index == filterIndex)
        EqFilter(
          index: f.index,
          enabled: f.enabled,
          type: f.type,
          freqHz: f.freqHz,
          gainDb: gain,
          q: f.q,
        )
      else
        f,
  ];
  return ParametricEq(
    preampDb: eq.preampDb,
    filters: filters,
  ).toParametricEqText();
}

// ---------------------------------------------------------------- 面板

enum _EqView { curve, bars }

/// EQ 可视化/编辑面板: 顶部 曲线/柱状 切换, 下方图表.
/// [text] 为 eqProfileText(null/空 = 未启用); 拖动柱状图松手后通过
/// [onChanged] 写回新文本(调用方负责更新 AppSettings 与 eqProfileName).
class EqCurvePanel extends StatefulWidget {
  const EqCurvePanel({super.key, required this.text, required this.onChanged});

  final String? text;
  final ValueChanged<String> onChanged;

  @override
  State<EqCurvePanel> createState() => _EqCurvePanelState();
}

class _EqCurvePanelState extends State<EqCurvePanel> {
  _EqView _view = _EqView.curve;

  /// 空文本时回退到内置默认曲线(10 段全 0 dB), 无需先导入即可编辑.
  String get _effectiveText {
    final text = widget.text?.trim() ?? '';
    return text.isEmpty ? defaultEqProfileText() : text;
  }

  @override
  Widget build(BuildContext context) {
    final text = _effectiveText;

    Widget body;
    try {
      final eq = parseParametricEq(text);
      body = _view == _EqView.curve
          ? _CurveChart(eq: eq)
          : _BarChart(eq: eq, onGainCommitted: _commitGain);
    } on EqProfileException catch (e) {
      body = _EmptyMessage(
        icon: Icons.error_outline,
        message: '曲线解析失败\n${e.message}',
        isError: true,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: SegmentedButton<_EqView>(
            segments: const [
              ButtonSegment(value: _EqView.curve, label: Text('曲线')),
              ButtonSegment(value: _EqView.bars, label: Text('柱状')),
            ],
            selected: {_view},
            showSelectedIcon: false,
            style: const ButtonStyle(
              visualDensity: VisualDensity(horizontal: -3, vertical: -3),
            ),
            onSelectionChanged: (s) => setState(() => _view = s.first),
          ),
        ),
        Expanded(child: body),
      ],
    );
  }

  void _commitGain(int filterIndex, double gain) {
    final text = _effectiveText;
    try {
      final eq = parseParametricEq(text);
      widget.onChanged(rewriteEqFilterGain(eq, filterIndex, gain));
    } on EqProfileException {
      // 解析失败时不写回, 界面已显示错误.
    }
  }
}

class _EmptyMessage extends StatelessWidget {
  const _EmptyMessage({
    required this.icon,
    required this.message,
    this.isError = false,
  });

  final IconData icon;
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = isError
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- 曲线图

class _CurveChart extends StatefulWidget {
  const _CurveChart({required this.eq});

  final ParametricEq eq;

  @override
  State<_CurveChart> createState() => _CurveChartState();
}

class _CurveChartState extends State<_CurveChart> {
  double? _probeFreq;

  static const _axisLabels = [
    20.0,
    50.0,
    100.0,
    500.0,
    1000.0,
    5000.0,
    10000.0,
    20000.0,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final labelH = 14.0;
        final chartSize = Size(
          size.width,
          (size.height - labelH).clamp(1.0, size.height),
        );
        double? probeDb;
        final probe = _probeFreq;
        if (probe != null) {
          probeDb = evaluateEqDb(widget.eq, [probe]).first;
        }
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _updateProbe(d.localPosition.dx, chartSize.width),
          onPanStart: (d) => _updateProbe(d.localPosition.dx, chartSize.width),
          onPanUpdate: (d) => _updateProbe(d.localPosition.dx, chartSize.width),
          onPanCancel: () => setState(() => _probeFreq = null),
          onPanEnd: (_) => setState(() => _probeFreq = null),
          child: CustomPaint(
            size: size,
            painter: _CurvePainter(
              eq: widget.eq,
              chartSize: chartSize,
              probeFreq: _probeFreq,
              probeDb: probeDb,
              axisLabels: _axisLabels,
              curveColor: theme.colorScheme.primary,
              gridColor: theme.colorScheme.onSurfaceVariant.withValues(
                alpha: 0.25,
              ),
              labelColor: theme.colorScheme.onSurfaceVariant,
              probeColor: theme.colorScheme.secondary,
              errorColor: theme.colorScheme.error,
            ),
          ),
        );
      },
    );
  }

  void _updateProbe(double dx, double width) {
    const minF = 20.0, maxF = 20000.0;
    final t = (dx / width).clamp(0.0, 1.0);
    setState(() => _probeFreq = minF * math.pow(maxF / minF, t));
  }
}

class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.eq,
    required this.chartSize,
    required this.probeFreq,
    required this.probeDb,
    required this.axisLabels,
    required this.curveColor,
    required this.gridColor,
    required this.labelColor,
    required this.probeColor,
    required this.errorColor,
  });

  final ParametricEq eq;
  final Size chartSize;
  final double? probeFreq;
  final double? probeDb;
  final List<double> axisLabels;
  final Color curveColor;
  final Color gridColor;
  final Color labelColor;
  final Color probeColor;
  final Color errorColor;

  @override
  void paint(Canvas canvas, Size size) {
    _drawGrid(canvas);

    // "0 dB 无 EQ" 参考虚线.
    final zeroY = eqCurveY(0, chartSize.height);
    final refPaint = Paint()
      ..color = gridColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, zeroY), Offset(chartSize.width, zeroY), refPaint);

    final points = computeCurve(eq, chartSize);
    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (final p in points.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = curveColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    // 频轴标注.
    for (final f in axisLabels) {
      _drawLabel(
        canvas,
        eqFreqLabel(f),
        eqCurveX(f, chartSize.width),
        chartSize.height + 1,
        labelColor,
        align: TextAlign.center,
      );
    }

    // 触摸读数.
    final freq = probeFreq;
    final db = probeDb;
    if (freq != null && db != null) {
      final x = eqCurveX(freq, chartSize.width);
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, chartSize.height),
        Paint()
          ..color = probeColor
          ..strokeWidth = 1,
      );
      final text =
          '${eqFreqLabel(freq)} Hz  ${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB';
      final tw = _textWidth(text, labelColor);
      var lx = x + 4;
      if (lx + tw > chartSize.width) lx = chartSize.width - tw - 2;
      canvas.drawRect(
        Rect.fromLTWH(lx - 2, 2, tw + 4, 14),
        Paint()..color = gridColor.withValues(alpha: 0.5),
      );
      _drawLabel(canvas, text, lx, 3, labelColor, align: TextAlign.left);
    }
  }

  void _drawGrid(Canvas canvas) {
    final paint = Paint()
      ..color = gridColor.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;
    for (final db in [-12.0, 12.0]) {
      final y = eqCurveY(db, chartSize.height);
      canvas.drawLine(Offset(0, y), Offset(chartSize.width, y), paint);
    }
  }

  double _textWidth(String text, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 9, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp.width;
  }

  void _drawLabel(
    Canvas canvas,
    String text,
    double x,
    double y,
    Color color, {
    TextAlign align = TextAlign.left,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: 9, color: color),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout();
    var dx = x;
    if (align == TextAlign.center) dx -= tp.width / 2;
    dx = dx.clamp(
      0.0,
      (chartSize.width - tp.width).clamp(0.0, 1 << 20).toDouble(),
    );
    tp.paint(canvas, Offset(dx, y));
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.eq != eq || old.probeFreq != probeFreq || old.chartSize != chartSize;
}

// ---------------------------------------------------------------- 柱状图

class _BarChart extends StatefulWidget {
  const _BarChart({required this.eq, required this.onGainCommitted});

  final ParametricEq eq;
  final void Function(int filterIndex, double gain) onGainCommitted;

  @override
  State<_BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<_BarChart> {
  static const _topPad = 14.0;
  static const _bottomPad = 18.0;

  int? _dragColumn;
  double? _dragStartDy;
  double? _previewGain;

  /// 按 Fc 排序的柱位(含 OFF, OFF 不响应拖动).
  List<EqFilter> get _sorted {
    final list = [...widget.eq.filters]
      ..sort((a, b) => a.freqHz.compareTo(b.freqHz));
    return list;
  }

  /// 起点 gain + 垂直位移(向上为正) → 步进 0.1 并 clamp ±24.
  double _gainFromDelta(double startGain, double dyDelta, double plotH) {
    final db = startGain - dyDelta * 48.0 / plotH;
    final stepped = (db * 10).roundToDouble() / 10.0;
    return stepped.clamp(-maxEqGainDb, maxEqGainDb).toDouble();
  }

  /// 把第 [i] 根柱的拖动回调直接挂到“立即接管 arena”的识别器上.
  /// 不能在下面再嵌套 GestureDetector: 它会和本识别器在同一个 arena 竞争,
  /// 识别器 pointer down 即 accept, 内层 GestureDetector 永远拿不到回调.
  void _bindColumnGestures(
    _EagerVerticalDragGestureRecognizer instance,
    int i,
    double plotH,
  ) {
    final enabled = _sorted[i].enabled;
    instance.onStart = enabled
        ? (DragStartDetails d) {
            setState(() {
              _dragColumn = i;
              _dragStartDy = d.localPosition.dy;
              _previewGain = _sorted[i].gainDb;
            });
          }
        : null;
    instance.onUpdate = enabled
        ? (DragUpdateDetails d) {
            if (_dragColumn != i || _dragStartDy == null) return;
            setState(() {
              _previewGain = _gainFromDelta(
                _sorted[i].gainDb,
                d.localPosition.dy - _dragStartDy!,
                plotH,
              );
            });
          }
        : null;
    instance.onEnd = enabled
        ? (DragEndDetails d) {
            if (_dragColumn == i) {
              widget.onGainCommitted(
                _sorted[i].index,
                _previewGain ?? _sorted[i].gainDb,
              );
            }
            setState(() {
              _dragColumn = null;
              _dragStartDy = null;
              _previewGain = null;
            });
          }
        : null;
    instance.onCancel = enabled
        ? () => setState(() {
            _dragColumn = null;
            _dragStartDy = null;
            _previewGain = null;
          })
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bars = _sorted;
    if (bars.isEmpty) {
      return const _EmptyMessage(
        icon: Icons.graphic_eq,
        message: '曲线中没有任何 filter',
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        final plotH = (h - _topPad - _bottomPad).clamp(1.0, h);
        final colW = constraints.maxWidth / bars.length;
        return Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
                size: Size(constraints.maxWidth, h),
                painter: _BarPainter(
                  eq: widget.eq,
                  bars: bars,
                  previewIndex: _dragColumn == null
                      ? null
                      : bars[_dragColumn!].index,
                  previewGain: _previewGain,
                  topPad: _topPad,
                  bottomPad: _bottomPad,
                  barColor: theme.colorScheme.primary,
                  offColor: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.35,
                  ),
                  gridColor: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.25,
                  ),
                  labelColor: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (var i = 0; i < bars.length; i++)
              Positioned(
                left: i * colW,
                width: colW,
                top: 0,
                height: h,
                child: RawGestureDetector(
                  behavior: HitTestBehavior.translucent,
                  // 用“立即接管 arena”的垂直拖动识别器: 否则外层 ListView
                  // 的滚动手势会在 arena 竞争中胜出, 柱状图在设置页里拖不动.
                  gestures: <Type, GestureRecognizerFactory>{
                    _EagerVerticalDragGestureRecognizer:
                        GestureRecognizerFactoryWithHandlers<
                          _EagerVerticalDragGestureRecognizer
                        >(
                          () => _EagerVerticalDragGestureRecognizer(),
                          (instance) => _bindColumnGestures(instance, i, plotH),
                        ),
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 立即接管手势 arena 的垂直拖动识别器.
///
/// 默认的 GestureDetector 垂直拖动在外层 ListView/滚动容器里会输给滚动手势
/// (arena 竞争), 导致柱状图在设置页里拖不动. 在 pointer down 时立刻 accept,
/// 图表区域的垂直拖动优先于页面滚动.
class _EagerVerticalDragGestureRecognizer
    extends VerticalDragGestureRecognizer {
  @override
  void addPointer(PointerDownEvent event) {
    super.addPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.eq,
    required this.bars,
    required this.previewIndex,
    required this.previewGain,
    required this.topPad,
    required this.bottomPad,
    required this.barColor,
    required this.offColor,
    required this.gridColor,
    required this.labelColor,
  });

  final ParametricEq eq;
  final List<EqFilter> bars;
  Size canvasSize = Size.zero;
  final int? previewIndex;
  final double? previewGain;
  final double topPad;
  final double bottomPad;
  final Color barColor;
  final Color offColor;
  final Color gridColor;
  final Color labelColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvasSize = size;
    final plotH = (size.height - topPad - bottomPad).clamp(1.0, size.height);
    final zeroY = topPad + plotH / 2;
    final pxPerDb = plotH / 48.0;

    // 0dB 基准线.
    canvas.drawLine(
      Offset(0, zeroY),
      Offset(size.width, zeroY),
      Paint()
        ..color = gridColor
        ..strokeWidth = 1,
    );

    final colW = size.width / bars.length;
    final barW = math.min(colW * 0.7, 40.0);
    for (var i = 0; i < bars.length; i++) {
      final f = bars[i];
      final gain = f.index == previewIndex && previewGain != null
          ? previewGain!
          : f.gainDb;
      final x = i * colW + (colW - barW) / 2;
      final gy = (zeroY - gain * pxPerDb).clamp(topPad, topPad + plotH);
      final paint = Paint()..color = f.enabled ? barColor : offColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x, math.min(zeroY, gy), x + barW, math.max(zeroY, gy)),
          const Radius.circular(2),
        ),
        paint,
      );
      // 数值标注(拖动中实时).
      _text(canvas, gain.toStringAsFixed(1), i * colW, colW, 2, center: true);
      // Fc/Q/类型 标注.
      final tag = '${f.type.name.toUpperCase()} ${eqFreqLabel(f.freqHz)}';
      _text(
        canvas,
        tag,
        i * colW,
        colW,
        size.height - bottomPad + 3,
        center: true,
      );
    }
  }

  void _text(
    Canvas canvas,
    String text,
    double x,
    double colW,
    double y, {
    bool center = false,
  }) {
    final size = canvasSize;
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        // token-ok: 曲线刻度是图表内最小标注(8sp), 再大就会压到曲线本体
        style: TextStyle(fontSize: 8, color: labelColor),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(colW, 8));
    final maxDx = math.max(size.width - tp.width, 0.0);
    final dx = center
        ? (x + (colW - tp.width) / 2).clamp(0.0, maxDx).toDouble()
        : x.clamp(0.0, maxDx).toDouble();
    tp.paint(canvas, Offset(dx, y));
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.eq != eq ||
      old.previewGain != previewGain ||
      old.previewIndex != previewIndex;
}
