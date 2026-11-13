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
    this.minMarqueeOverflow = 8,
  });

  final String text;

  /// 文本样式(字号/颜色/灰显等由调用方给).
  final TextStyle? style;

  /// 仅供语义/退化路径使用; 跑马灯本体永远单行.
  final int maxLines;

  /// 触发滚动的最小溢出量(px).
  ///
  /// 溢出几像素就滚一整轮会显得"明明放得下却在动"(用户反馈), 因此留一条死区;
  /// 落在死区里的文本按 ellipsis 静止显示.
  final double minMarqueeOverflow;

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

  /// 在途 postFrame 守卫: 宽度快速连续变化时同一帧队列里可能挂了多个
  /// _start 回调, 每个都会建 AnimationController => SingleTickerProviderStateMixin
  /// 的 "multiple tickers" 断言。同一时刻最多只允许一个在途 _start。
  bool _startScheduled = false;

  /// 实测: 即使 _start 里先 dispose 旧 controller 再建新的,
  /// SingleTickerProviderStateMixin 仍会报 "multiple tickers"(同帧销毁重建不豁免)。
  /// 因此 controller 整个 State 生命周期只建一次, 重排时只改 duration 并重建
  /// TweenSequence(AnimationController.duration 可变), 彻底避免二次 createTicker。

  /// 标识当前动画对应的 (文本, 视口宽) 组合; 变了就要重建.
  int? _animKey;

  @override
  void dispose() {
    // controller 复用整个 State 生命周期, 只在这里销毁一次(无泄漏)。
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  /// 用与真实渲染一致的 style + textScaler 测量单行宽度与行高.
  ///
  /// 两个历史 bug 都因"测量口径 != 渲染口径":
  /// 1. 漏传 textScaler(默认 1.0): 用户开大字体(如 1.25)时测得宽度偏小 25%,
  ///    导致"放得下"误判不滚动, 或临界时真实文本撑破父约束(Right overflowed by 8.6px);
  /// 2. 漏合并 DefaultTextStyle: [Text] 是按 DefaultTextStyle.style.merge(style) 渲染的,
  ///    只拿 widget.style 测量会偏小(典型: AppBar 标题不传 style, 继承 20sp, 而测量按
  ///    TextPainter 默认 14sp), 于是"放得下"误判、滚动距离也算短. 见 [effectiveStyle].
  /// 与 [Text] 内部一致的有效样式: DefaultTextStyle.style.merge(widget.style).
  /// 测量与渲染必须都用这一份, 否则宽度对不上(见 [_measure] 注释).
  TextStyle effectiveStyle(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final style = widget.style;
    return style == null ? base : base.merge(style);
  }

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

  void _start(double distance, int key) {
    // 无论 key 是否仍有效都先消费在途标志, 否则失效回调会让后续重排永远无法再调度。
    _startScheduled = false;
    if (!mounted || _animKey != key) return;
    final scrollMs = (distance / _speed * 1000).round().clamp(120, 60000);
    final controller = _controller ??= AnimationController(
      vsync: this,
      duration: Duration(milliseconds: scrollMs + _pauseMs * 2),
    );
    controller.duration = Duration(milliseconds: scrollMs + _pauseMs * 2);
    _offset = controller.drive(
      TweenSequence<double>([
        // 起点停 1s
        TweenSequenceItem(
          tween: ConstantTween(0.0),
          weight: _pauseMs.toDouble(),
        ),
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: distance),
          weight: scrollMs.toDouble(),
        ),
        // 尾部停 1s, 然后由 controller.repeat() 瞬跳回起点 —— 单向跑马灯。
        // 不做反向回滚: 反向段会让画面同时存在向左/向右两种位移, 视觉很乱(用户反馈)。
        TweenSequenceItem(
          tween: ConstantTween(distance),
          weight: _pauseMs.toDouble(),
        ),
      ]),
    );
    _controller = controller;
    controller
      ..stop()
      ..value = 0
      ..repeat();
    setState(() {});
  }

  void _stop() {
    // 不 dispose controller(复用, 避免 multiple tickers), 只停动画并清状态。
    _controller?.stop();
    _offset = null;
    _animKey = null;
    _startScheduled = false;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final scaler = MediaQuery.textScalerOf(context);
        // 测量与渲染共用同一份有效样式(DefaultTextStyle.merge(style)),
        // 否则 AppBar 这类「不传 style、靠继承」的场景宽度会算错(见 _measure 注释).
        final effective = effectiveStyle(context);
        final (textWidth, textHeight) = _measure(
          widget.text,
          effective,
          scaler,
        );
        final plain = Text(
          widget.text,
          style: effective,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        );
        // 宽度无界(如 UnconstrainedBox 里): 退化为 ellipsis, 不测量不滚动.
        if (!maxWidth.isFinite) return plain;
        // 是否值得滚: 溢出必须超过死区 minMarqueeOverflow(默认 8px).
        // 之前用的是一条 1px 容差, 溢出 2px 也会滚一整轮 -> 看起来"明明放得下却在动".
        final fits = textWidth - maxWidth <= widget.minMarqueeOverflow;
        if (fits || reduceMotion) {
          if (_offset != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _offset != null) _stop();
            });
          }
          return plain;
        }
        // 需要滚动: 单行 + ClipRect + 位移.
        final distance = textWidth - maxWidth + _tailGap;
        // key 必须按「内容」而不是 identityHashCode(String): 父级每次重建都会产生
        // 新的 String 实例(如 '已选 $n 句'), 用实例身份会让 key 每帧变化 -> _start 反复
        // 从 0 重播, 视觉上是"一直在滚但总停在开头".
        final key = Object.hash(widget.text, maxWidth, scaler, effective);
        if (!_startScheduled && (_offset == null || _animKey != key)) {
          _animKey = key;
          _startScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _start(distance, key),
          );
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
                : RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _offset!,
                      // 滚动中的文本必须按"测量出的全文宽"自由排版:
                      // 若仍吃 SizedBox 的 maxWidth, 会先被 ellipsis/clip 截到
                      // 视口宽再整体平移 => "滚的只是被截断的那一截".
                      // OverflowBox 把子项约束放宽到全文宽(高度钉在实测行高),
                      // 配合外层 ClipRect 裁切.
                      //
                      // child 只在这里构造一次: 之前把它写在 builder 里, 等于每帧
                      // 新建一个 Text => 每帧重排整段 paragraph(跑马灯丢帧/耗电的真源).
                      child: OverflowBox(
                        alignment: Alignment.centerLeft,
                        minWidth: textWidth,
                        maxWidth: textWidth,
                        minHeight: textHeight,
                        maxHeight: textHeight,
                        child: Text(
                          widget.text,
                          style: effective,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.visible,
                          textScaler: scaler,
                        ),
                      ),
                      builder: (context, child) => Transform.translate(
                        offset: Offset(-_offset!.value, 0),
                        child: child,
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}
