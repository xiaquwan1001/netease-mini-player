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

  double _measure(String text, TextStyle? style) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
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
        final plain = Text(
          widget.text,
          style: widget.style,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
        // 宽度无界(如 UnconstrainedBox 里): 退化为 ellipsis, 不测量不滚动.
        if (!maxWidth.isFinite) return plain;
        final fits = _measure(widget.text, widget.style) <= maxWidth;
        if (fits || reduceMotion) {
          if (_controller != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _controller != null) _stop();
            });
          }
          return plain;
        }
        // 需要滚动: 单行 + ClipRect + 位移.
        final distance = _measure(widget.text, widget.style) - maxWidth + _tailGap;
        final key = '${identityHashCode(widget.text)}|$maxWidth|${widget.style?.fontSize}';
        if (_offset == null || _animKey != key) {
          _animKey = key;
          WidgetsBinding.instance.addPostFrameCallback((_) => _start(distance, key));
        }
        return ClipRect(
          child: SizedBox(
            width: maxWidth,
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
                      return Align(
                        alignment: Alignment.centerLeft,
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Transform.translate(
                          offset: Offset(-_offset!.value, 0),
                          child: Text(
                            widget.text,
                            style: widget.style,
                            maxLines: 1,
                            softWrap: false,
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
