import 'package:flutter/material.dart';

/// 单行跑马灯文本: 放得下就当普通 Text 渲染; 放不下才横向往复滚动.
///
/// - 永远单行(`maxLines: 1` + `softWrap: false`), 不会出现逐字竖排;
/// - 外层 [ClipRect] 防止滚动时超界;
/// - 点按不拦截(本身不响应手势, 外层 InkWell 仍可点);
/// - [TickerMode]/Offstage 不可见时 ticker 会被静音, 不后台耗电;
/// - 系统开启 reduce motion(MediaQuery.disableAnimations)时退化为 ellipsis,
///   不打任何动画.
class MarqueeText extends StatefulWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
  });

  final String text;

  /// 文本样式(字号/颜色/灰显等由调用方给).
  final TextStyle? style;

  /// 仅供语义/退化路径使用; 跑马灯本体永远单行.
  final int maxLines;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  /// 滚动速度(px/s)与每轮首尾停顿(ms).
  static const double _speed = 34;
  static const int _pauseMs = 1000;

  /// 文本超出视口后, 每轮滚动额外多走的最尾空隙(px).
  static const double _tailGap = 24;

  AnimationController? _controller;
  Animation<double>? _offset;

  /// 标识当前动画对应的 (文本, 视口宽) 组合; 变了就要重建.
  String? _animKey;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  /// 用与真实渲染一致的 textScaler 测量单行宽度与行高.
  /// 之前漏传 textScaler(默认 1.0), 用户开大字体(如 1.25)时测得宽度偏小 25%,
  /// 导致"放得下"误判不滚动, 或临界时真实文本撑破父约束(Right overflowed by 8.6px).
  (double width, double height) _measure(
    String text,
    TextStyle? style,
    TextScaler scaler,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: scaler,
    )..layout();
    final size = (tp.width, tp.height);
    tp.dispose();
    return size;
  }

  void _start(double distance, String key) {
    if (!mounted || _animKey != key) return;
    _controller?.dispose();
    final scrollMs = (distance / _speed * 1000).round().clamp(120, 60000);
    final controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: scrollMs * 2 + _pauseMs * 2),
    );
    _offset = controller.drive(
      TweenSequence<double>([
        // 起点停 1s
        TweenSequenceItem(tween: ConstantTween(0.0), weight: _pauseMs.toDouble()),
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: distance),
          weight: scrollMs.toDouble(),
        ),
        // 尾部停 1s
        TweenSequenceItem(
          tween: ConstantTween(distance),
          weight: _pauseMs.toDouble(),
        ),
        // 往复拉回
        TweenSequenceItem(
          tween: Tween(begin: distance, end: 0.0),
          weight: scrollMs.toDouble(),
        ),
      ]),
    );
    _controller = controller;
    controller.repeat();
    setState(() {});
  }

  void _stop() {
    _controller?.dispose();
    _controller = null;
    _offset = null;
    _animKey = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final scaler = MediaQuery.textScalerOf(context);
        final (textWidth, textHeight) = _measure(
          widget.text,
          widget.style,
          scaler,
        );
        final plain = Text(
          widget.text,
          style: widget.style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
        // 宽度无界(如 UnconstrainedBox 里): 退化为 ellipsis, 不测量不滚动.
        if (!maxWidth.isFinite) return plain;
        final fits = textWidth <= maxWidth;
        if (fits || reduceMotion) {
          if (_controller != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _controller != null) _stop();
            });
          }
          return plain;
        }
        // 需要滚动: 单行 + ClipRect + 位移.
        final distance = textWidth - maxWidth + _tailGap;
        final key = '${identityHashCode(widget.text)}|$maxWidth|${scaler.hashCode}';
        if (_offset == null || _animKey != key) {
          _animKey = key;
          WidgetsBinding.instance.addPostFrameCallback((_) => _start(distance, key));
        }
        return ClipRect(
          child: SizedBox(
            width: maxWidth,
            height: textHeight,
            child: _offset == null
                ? Align(
                    alignment: Alignment.centerLeft,
                    widthFactor: 1,
                    heightFactor: 1,
                    child: plain,
                  )
                : AnimatedBuilder(
                    animation: _offset!,
                    builder: (context, _) {
                      // 滚动中的文本必须按"测量出的全文宽"自由排版:
                      // 若仍吃 SizedBox 的 maxWidth, 会先被 ellipsis/clip 截到
                      // 视口宽再整体平移 => "滚的只是被截断的那一截".
                      // OverflowBox 把子项约束放宽到全文宽(高度钉在实测行高),
                      // 配合外层 ClipRect 裁切.
                      return OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: textWidth,
                        maxWidth: textWidth,
                        minHeight: textHeight,
                        maxHeight: textHeight,
                        child: Transform.translate(
                          offset: Offset(-_offset!.value, 0),
                          child: Text(
                            widget.text,
                            style: widget.style,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.visible,
                            textScaler: scaler,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}
