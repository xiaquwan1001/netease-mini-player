import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 触发跑马灯的最小溢出量(px).
///
/// 溢出几像素就滚一整轮会显得"明明放得下却在动"(用户反馈), 因此留一条死区;
/// 落在死区里的内容按静止显示。单行文本([MarqueeText])与逐字歌词共用这一口径。
const double kMarqueeMinOverflow = 8;

/// 单行跑马灯文本: 放得下就当普通 Text 渲染; 放不下才横向往复滚动.
///
/// - 永远单行(`maxLines: 1` + `softWrap: false`), 不会出现逐字竖排;
/// - 外层 [ClipRect] 防止滚动时超界;
/// - 点按不拦截(本身不响应手势, 外层 InkWell 仍可点);
/// - 在 [TickerMode] 关闭的子树里 ticker 会被静音, 不后台耗电;
///   注意 [Offstage] **不会**静音 ticker(离屏动画照旧跑), 需要静音时要自己套
///   [TickerMode](见 detail_faces.dart / tab_builder.dart 的用法);
/// - 系统开启 reduce motion(MediaQuery.disableAnimations)时退化为 ellipsis,
///   不打任何动画.
///
/// 滚动内核是 [MarqueeScroll](本文件), 不是单独一套动画: 逐字歌词这类自绘内容
/// 直接用 [MarqueeScroll], 全仓只有一台跑马灯实现。
class MarqueeText extends StatelessWidget {
  const MarqueeText(
    this.text, {
    super.key,
    this.style,
    this.maxLines = 1,
    this.minMarqueeOverflow = kMarqueeMinOverflow,
    this.textAlign,
  });

  final String text;

  /// 文本样式(字号/颜色/灰显等由调用方给).
  final TextStyle? style;

  /// 仅供语义/退化路径使用; 跑马灯本体永远单行.
  final int maxLines;

  /// 触发滚动的最小溢出量(px), 见 [kMarqueeMinOverflow].
  final double minMarqueeOverflow;

  /// 静止时的对齐口径; 滚动中段落宽 == 全文宽, 该值不影响滚动画面.
  ///
  /// 默认 null(Text 默认 start): 歌名之类的调用方都是"按内容宽排版后由父级居中",
  /// 只有歌词这种**需要显式中心对齐**的场景才传 [TextAlign.center]。
  final TextAlign? textAlign;

  /// 与 [Text] 内部一致的有效样式: DefaultTextStyle.style.merge(widget.style).
  /// 测量与渲染必须都用这一份, 否则宽度对不上(见 [_measure] 注释).
  TextStyle effectiveStyle(BuildContext context) {
    final base = DefaultTextStyle.of(context).style;
    final style = this.style;
    return style == null ? base : base.merge(style);
  }

  /// 用与真实渲染一致的 style + textScaler 测量单行宽度与行高.
  ///
  /// 两个历史 bug 都因"测量口径 != 渲染口径":
  /// 1. 漏传 textScaler(默认 1.0): 用户开大字体(如 1.25)时测得宽度偏小 25%,
  ///    导致"放得下"误判不滚动, 或临界时真实文本撑破父约束(Right overflowed by 8.6px);
  /// 2. 漏合并 DefaultTextStyle: [Text] 是按 DefaultTextStyle.style.merge(style) 渲染的,
  ///    只拿 widget.style 测量会偏小(典型: AppBar 标题不传 style, 继承 20sp, 而测量按
  ///    TextPainter 默认 14sp), 于是"放得下"误判、滚动距离也算短.
  (double width, double height) _measure(
    String text,
    TextStyle? style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: direction,
      textScaler: scaler,
    )..layout();
    final size = (tp.width, tp.height);
    tp.dispose();
    return size;
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
          text,
          effective,
          scaler,
          Directionality.of(context),
        );
        final plain = Text(
          text,
          style: effective,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          textAlign: textAlign,
        );
        // 宽度无界(如 UnconstrainedBox 里): 退化为 ellipsis, 不测量不滚动.
        if (!maxWidth.isFinite) return plain;
        // 是否值得滚: 溢出必须超过死区 minMarqueeOverflow.
        // 之前用的是一条 1px 容差, 溢出 2px 也会滚一整轮 -> 看起来"明明放得下却在动".
        final fits = textWidth - maxWidth <= minMarqueeOverflow;
        if (fits || reduceMotion) return plain;
        // 需要滚动: 交给统一的跑马灯视口(它按内容自然宽排版 + 位移).
        return MarqueeScroll(
          contentWidth: textWidth,
          height: textHeight,
          // 滚动中的文本必须按"测量出的全文宽"自由排版:
          // 若仍吃视口的 maxWidth, 会先被 ellipsis/clip 截到视口宽再整体平移
          // => "滚的只是被截断的那一截".
          child: Text(
            text,
            style: effective,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            textAlign: textAlign,
            textScaler: scaler,
          ),
        );
      },
    );
  }
}

/// 通用横向跑马灯视口: 内容自然宽度 [contentWidth], 视口宽由父约束决定.
///
/// 单向滚动(起点停 → 向左滚 → 尾部停 → 瞬跳回起点重复), 不做反向回滚:
/// 反向段会让画面同时存在向左/向右两种位移, 视觉很乱(用户反馈)。
///
/// - [child] 必须按 [contentWidth] 自行排版(比视口宽, 由外层 [ClipRect] 裁切);
/// - 视口无界或内容放得下时停在起点, 不排帧;
/// - 系统 reduce motion 时同样退化为静止;
/// - [MarqueeText] 的滚动分支就是它; 逐字歌词的自绘内容直接复用, 不另写一套。
class MarqueeScroll extends StatefulWidget {
  const MarqueeScroll({
    super.key,
    required this.contentWidth,
    required this.height,
    required this.child,
    this.speed = 34,
    this.pauseMs = 1000,
    this.tailGap = 24,
  });

  /// 内容自然宽度(px); 由调用方用与渲染一致的样式测量得到.
  final double contentWidth;

  /// 内容行高(px); 视口高度与之一致, 避免 Column 里行高抖动.
  final double height;

  final Widget child;

  /// 滚动速度(px/s).
  final double speed;

  /// 每轮首尾停顿(ms).
  final int pauseMs;

  /// 内容超出视口后, 每轮滚动额外多走的最尾空隙(px).
  final double tailGap;

  @override
  State<MarqueeScroll> createState() => _MarqueeScrollState();
}

class _MarqueeScrollState extends State<MarqueeScroll>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _offset;

  /// 在途 postFrame 守卫: 宽度快速连续变化时同一帧队列里可能挂了多个
  /// _start 回调, 每个都会建 AnimationController => SingleTickerProviderStateMixin
  /// 的 "multiple tickers" 断言。同一时刻最多只允许一个在途 _start。
  bool _startScheduled = false;

  /// 在途停止守卫(同上: 一帧内多次 build 只停一次).
  bool _stopScheduled = false;

  /// 实测: 即使 _start 里先 dispose 旧 controller 再建新的,
  /// SingleTickerProviderStateMixin 仍会报 "multiple tickers"(同帧销毁重建不豁免)。
  /// 因此 controller 整个 State 生命周期只建一次, 重排时只改 duration 并重建
  /// TweenSequence(AnimationController.duration 可变), 彻底避免二次 createTicker。

  /// 标识当前动画对应的 (内容宽, 视口宽) 组合; 变了就要重建.
  int? _animKey;

  @override
  void dispose() {
    // controller 复用整个 State 生命周期, 只在这里销毁一次(无泄漏)。
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  void _start(double distance, int key) {
    // 无论 key 是否仍有效都先消费在途标志, 否则失效回调会让后续重排永远无法再调度。
    _startScheduled = false;
    if (!mounted || _animKey != key) return;
    final pause = widget.pauseMs;
    final scrollMs = (distance / widget.speed * 1000).round().clamp(120, 60000);
    final controller = _controller ??= AnimationController(
      vsync: this,
      duration: Duration(milliseconds: scrollMs + pause * 2),
    );
    controller.duration = Duration(milliseconds: scrollMs + pause * 2);
    _offset = controller.drive(
      TweenSequence<double>([
        // 起点停 1s
        TweenSequenceItem(tween: ConstantTween(0.0), weight: pause.toDouble()),
        TweenSequenceItem(
          tween: Tween(begin: 0.0, end: distance),
          weight: scrollMs.toDouble(),
        ),
        // 尾部停 1s, 然后由 controller.repeat() 瞬跳回起点 —— 单向跑马灯。
        TweenSequenceItem(
          tween: ConstantTween(distance),
          weight: pause.toDouble(),
        ),
      ]),
    );
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

  /// build 阶段不能直接 setState: 把"停止"推到帧后执行, 一帧最多一次.
  void _scheduleStop() {
    if (_offset == null || _stopScheduled) return;
    _stopScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _stopScheduled = false;
      if (!mounted || _offset == null) return;
      _stop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    // 内容按自然宽排版(视口更窄, 由外层 ClipRect 裁切).
    final content = OverflowBox(
      alignment: Alignment.centerLeft,
      minWidth: widget.contentWidth,
      maxWidth: widget.contentWidth,
      minHeight: widget.height,
      maxHeight: widget.height,
      child: widget.child,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        // 视口无界: 不滚也不裁, 直接按内容宽渲染(调用方通常已给有限宽).
        if (!maxWidth.isFinite) return content;
        final distance = widget.contentWidth - maxWidth + widget.tailGap;
        if (reduceMotion || distance <= 0) {
          _scheduleStop();
          return ClipRect(
            child: SizedBox(
              width: maxWidth,
              height: widget.height,
              child: content,
            ),
          );
        }
        // key 必须按「内容宽 + 视口宽」而不是 identityHashCode(String): 父级每次
        // 重建都可能产生新实例, 用实例身份会让 key 每帧变化 -> 反复从 0 重播,
        // 视觉上是"一直在滚但总停在开头".
        final key = Object.hash(widget.contentWidth, maxWidth);
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
            height: widget.height,
            child: _offset == null
                ? content
                : RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _offset!,
                      // child 只在这里构造一次: 写在 builder 里等于每帧新建一个
                      // 子树 => 每帧重排整段内容(跑马灯丢帧/耗电的真源).
                      child: content,
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

/// 只有"播放中"才让子树里的跑马灯动: 用 [TickerMode] 静音 ticker.
///
/// 与"暂停时换成静态 Text"相比, 这里**不切换 widget 类型**: 暂停时动画停在当前
/// 偏移、零帧渲染(不白烧 CPU), 继续播放时从原位接着滚, 不会整行跳回行首。
/// [playing] 为 null(没有播放状态可用, 如静态歌词预览)视为未播放。
///
/// 歌词的当前行用它包住跑马灯; 非当前行不进这棵树(仍是 ellipsis)。
class MarqueePlayGate extends StatelessWidget {
  const MarqueePlayGate({
    super.key,
    required this.playing,
    required this.child,
  });

  final ValueListenable<bool>? playing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final listenable = playing;
    if (listenable == null) return TickerMode(enabled: false, child: child);
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (context, playing, child) =>
          TickerMode(enabled: playing, child: child!),
      child: child,
    );
  }
}
