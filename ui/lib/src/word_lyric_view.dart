import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'layout.dart' show rowExtentFor;

/// 逐字(karaoke)歌词的纯展示组件。
///
/// 设计约束:
/// - **不拉 FFI、不读全局单例**: 数据([WordLyricLineData])与播放位置
///   (positionMs, `ValueListenable<int>` 毫秒)全部由调用方注入, 可在 widget
///   test 里直接 pump 驱动;
/// - 位置 tick 只重建**当前行**(其余行是静态 Text, 且各行有 RepaintBoundary),
///   行下标变化时最多重建两行, 不会整页 setState;
/// - 活动行用 [KaraokePainter] 双层绘制(底层未唱色 + 顶层已唱色按词矩形裁切,
///   词内按 progress 渐变), 不再每 120ms 一台阶;
/// - [KaraokeLine] 内部用 Ticker 把位置插值到 ~60fps, 只驱动重绘(改 `repaint`
///   的 ValueListenable), **不 setState**、不重建整棵 widget 树;
/// - 系统开启 reduce motion(MediaQuery.disableAnimations)时不插值, 只按传入
///   位置的 state 跳变(与 MarqueeText 的 reduce motion 策略一致);
/// - 数据为空显示空态文案; 词文本含空格/标点原样渲染。

/// 一个词: 毫秒时间窗 + 文本。
class WordLyricWord {
  const WordLyricWord({
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  final int startMs;
  final int endMs;
  final String text;
}

/// 一行逐字歌词。词表为空时退化为整行(startMs..endMs 一次性高亮)。
class WordLyricLineData {
  const WordLyricLineData({
    required this.startMs,
    required this.endMs,
    required this.words,
    this.sub,
  });

  final int startMs;
  final int endMs;
  final List<WordLyricWord> words;

  /// 行级翻译(来自 tlyric 按行首对齐), 可为 null。
  final String? sub;
}

/// 整行纯文本(词拼回去; 词表为空时退回占位符 "♪")。
String karaokeLineText(WordLyricLineData line) =>
    line.words.isEmpty ? '♪' : [for (final w in line.words) w.text].join();

/// 返回 [0, lines.length) 的行下标; -1 表示还没唱到第一行。
/// [lines] 必须按 startMs 升序。
int wordLineIndexAt(List<WordLyricLineData> lines, int positionMs) {
  var lo = 0;
  var hi = lines.length - 1;
  var found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].startMs <= positionMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

/// 行内的着色决策(纯逻辑, 便于单测):
/// 每个词给一个状态与进度(progress 仅对“当前词”有意义, 0..1)。
enum WordHighlightState { sung, current, upcoming }

class WordSpanStyle {
  const WordSpanStyle(this.state, this.progress, this.text);

  final WordHighlightState state;
  final double progress;
  final String text;
}

/// 纯逻辑: 给定一行与位置, 算出每个词的着色状态与当前词进度。
/// 词表为空时退化为整行(行窗内为 current)。
List<WordSpanStyle> wordStylesAt(WordLyricLineData line, int positionMs) {
  if (line.words.isEmpty) {
    final inLine = positionMs >= line.startMs && positionMs < line.endMs;
    return [
      WordSpanStyle(
        inLine ? WordHighlightState.current : WordHighlightState.upcoming,
        0,
        '♪',
      ),
    ];
  }
  return [
    for (final w in line.words)
      if (positionMs >= w.startMs &&
          (w.endMs <= w.startMs || positionMs < w.endMs))
        WordSpanStyle(
          w.endMs <= w.startMs
              ? WordHighlightState
                    .sung // 零时长词: 到点即视为已唱
              : WordHighlightState.current,
          w.endMs <= w.startMs
              ? 1
              : (positionMs - w.startMs) / (w.endMs - w.startMs),
          w.text,
        )
      else if (positionMs >= w.endMs)
        WordSpanStyle(WordHighlightState.sung, 1, w.text)
      else
        WordSpanStyle(WordHighlightState.upcoming, 0, w.text),
  ];
}

/// 纯逻辑: 「每词状态+进度」+「每词矩形」→ 需要裁切的矩形列表。
///
/// - [WordHighlightState.upcoming]: 不裁(底层全行色已经覆盖);
/// - [WordHighlightState.sung]: 整词矩形;
/// - [WordHighlightState.current]: 左边 `progress × 词宽`(progress<=0 不产生矩形);
/// - 相邻且竖直对齐(容差 0.5px)的矩形会合并成一个, 避免逐词 clip 留下接缝,
///   也让"已唱并集"在一次 clipPath 里连续。
///
/// [boxes] 与 [styles] 一一对应; `null`/空矩形(被 ellipsis 截掉的词)跳过。
List<Rect> karaokeClipRects(List<WordSpanStyle> styles, List<Rect?> boxes) {
  final raw = <Rect>[];
  final n = styles.length < boxes.length ? styles.length : boxes.length;
  for (var i = 0; i < n; i++) {
    final box = boxes[i];
    if (box == null || box.width <= 0 || box.height <= 0) continue;
    final s = styles[i];
    switch (s.state) {
      case WordHighlightState.upcoming:
        break;
      case WordHighlightState.sung:
        raw.add(box);
      case WordHighlightState.current:
        final p = s.progress.isFinite ? s.progress.clamp(0.0, 1.0) : 0.0;
        final w = box.width * p;
        if (w > 0) raw.add(Rect.fromLTWH(box.left, box.top, w, box.height));
    }
  }
  return _mergeAdjacent(raw);
}

/// 把水平相邻(且上下对齐)的矩形合并; 输入按整行从左到右的顺序给出。
List<Rect> _mergeAdjacent(List<Rect> rects) {
  if (rects.length < 2) return rects;
  final out = <Rect>[rects.first];
  for (final r in rects.skip(1)) {
    final last = out.last;
    final aligned =
        (r.top - last.top).abs() <= 0.5 &&
        (r.height - last.height).abs() <= 0.5;
    if (aligned && r.left <= last.right + 0.5) {
      out[out.length - 1] = Rect.fromLTRB(
        last.left,
        last.top,
        r.right > last.right ? r.right : last.right,
        last.bottom,
      );
    } else {
      out.add(r);
    }
  }
  return out;
}

/// 逐字歌词视图。固定 itemExtent 的行级列表 + 当前行逐字着色 + 行级自动滚动。
class WordLyricView extends StatefulWidget {
  const WordLyricView({
    super.key,
    required this.lines,
    required this.positionMs,
    this.playing,
    this.controller,
    /// 行高; 不传 = [kRowExtent] × 系统字号(见 [rowExtentFor])。
    this.itemExtent,
    this.emptyText = '暂无歌词',
    this.padding,
    this.showTranslation = true,
    this.selected = const <int>{},
    this.onLineTap,
    this.onLineLongPress,
    this.autoScroll = true,
  });

  /// 行数据(升序); 空列表显示空态。
  final List<WordLyricLineData> lines;

  /// 当前播放位置(毫秒)。用 ValueListenable 注入, 避免父级每 tick setState。
  final ValueListenable<int> positionMs;

  /// 是否正在播放。为 null 或为 false 时不插值(仅按 positionMs 的 state 跳变),
  /// 这样静态/测试场景不会排帧(pumpAndSettle 能收敛), 暂停时也不白烧 CPU。
  final ValueListenable<bool>? playing;

  final ScrollController? controller;
  final double? itemExtent;
  final String emptyText;
  final EdgeInsetsGeometry? padding;

  /// 翻译开关(关掉时不渲染行级 sub)
  final bool showTranslation;

  /// 多选状态下选中的行下标
  final Set<int> selected;

  /// 点/长按某一行(多选入口); 为 null 时无反馈
  final void Function(int index)? onLineTap;
  final void Function(int index)? onLineLongPress;

  /// 跟随播放自动滚动; 用户手动滚动时由调用方置 false, 点"定位"再置回 true
  final bool autoScroll;

  @override
  State<WordLyricView> createState() => _WordLyricViewState();
}

class _WordLyricViewState extends State<WordLyricView> {
  /// 当前行下标(-1 = 未开始)。由 positionMs 派生: 行变化才通知, 行内 tick 不发。
  final ValueNotifier<int> _activeIndex = ValueNotifier<int>(-1);

  @override
  void initState() {
    super.initState();
    widget.positionMs.addListener(_onPosition);
    _onPosition();
  }

  @override
  void didUpdateWidget(covariant WordLyricView old) {
    super.didUpdateWidget(old);
    if (old.positionMs != widget.positionMs) {
      old.positionMs.removeListener(_onPosition);
      widget.positionMs.addListener(_onPosition);
      _activeIndex.value = -1;
      _onPosition();
    }
    // 恢复跟随(定位按钮/seek): 位置可能停在原句没变, 也要立刻把列表滚回当前行
    if (!old.autoScroll && widget.autoScroll) {
      _scrollTo(_activeIndex.value);
    }
  }

  @override
  void dispose() {
    widget.positionMs.removeListener(_onPosition);
    _activeIndex.dispose();
    super.dispose();
  }

  void _onPosition() {
    final pos = widget.positionMs.value;
    final idx = widget.lines.isEmpty ? -1 : wordLineIndexAt(widget.lines, pos);
    if (idx != _activeIndex.value) {
      _activeIndex.value = idx;
      _scrollTo(idx);
    }
  }

  void _scrollTo(int idx) {
    if (!widget.autoScroll) return;
    final controller = widget.controller;
    if (controller == null || !controller.hasClients || idx < 0) return;
    final position = controller.position;
    final extent = widget.itemExtent ?? rowExtentFor(context);
    final target = idx * extent - (position.viewportDimension - extent) / 2;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    controller.animateTo(
      clamped,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) {
      return Center(child: Text(widget.emptyText));
    }
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: _activeIndex,
      builder: (context, activeIndex, _) => ListView.builder(
        controller: widget.controller,
        itemExtent: widget.itemExtent ?? rowExtentFor(context),
        padding:
            widget.padding ??
            const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
        itemCount: widget.lines.length,
        itemBuilder: (context, i) {
          final line = widget.lines[i];
          final isActive = i == activeIndex;
          final isSelected = widget.selected.contains(i);
          return RepaintBoundary(
            child: GestureDetector(
              key: ValueKey('word-lyric-line-$i'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.onLineTap == null
                  ? null
                  : () => widget.onLineTap!(i),
              onLongPress: widget.onLineLongPress == null
                  ? null
                  : () => widget.onLineLongPress!(i),
              child: Container(
                decoration: isSelected
                    ? BoxDecoration(
                        color: scheme.primary.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      )
                    : null,
                child: isActive
                    ? ValueListenableBuilder<int>(
                        valueListenable: widget.positionMs,
                        builder: (context, pos, _) => KaraokeLine(
                          line: line,
                          positionMs: pos,
                          playing: widget.playing,
                          sungColor: scheme.primary,
                          upcomingColor: scheme.onSurfaceVariant.withValues(
                            alpha: 0.55,
                          ),
                          sub: widget.showTranslation ? line.sub : null,
                          subColor: scheme.primary.withValues(alpha: 0.8),
                        ),
                      )
                    : _StaticWordLine(
                        line: line,
                        scheme: scheme,
                        isSelected: isSelected,
                        showTranslation: widget.showTranslation,
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _StaticWordLine extends StatelessWidget {
  const _StaticWordLine({
    required this.line,
    required this.scheme,
    this.isSelected = false,
    this.showTranslation = true,
  });

  final WordLyricLineData line;
  final ColorScheme scheme;
  final bool isSelected;
  final bool showTranslation;

  @override
  Widget build(BuildContext context) {
    return _LineBody(
      main: TextSpan(
        text: karaokeLineText(line),
        style: TextStyle(
          fontSize: karaokeFontSize,
          color: isSelected ? scheme.onSurface : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w400,
        ),
      ),
      sub: showTranslation ? line.sub : null,
      subColor: scheme.outline,
    );
  }
}

/// 行文本字号。静态行与活动行**必须一致**: 之前活动行放大到 18/w600,
/// 行切换时整行重排 + 横向抖动。
const double karaokeFontSize = 15;

/// 活动行文本样式(只加深字重, 不改字号)。
const TextStyle karaokeActiveTextStyle = TextStyle(
  fontSize: karaokeFontSize,
  fontWeight: FontWeight.w600,
);

/// 活动行: 双层绘制 + (可选)本地插值。
///
/// 双层绘制: 底层用 [upcomingColor] 画整行; 顶层用 [sungColor] 画同一行文本,
/// 裁切到「已唱词矩形 ∪ 当前词左起 progress×词宽」, 右缘再加一道线性渐变遮罩
/// 做软边 —— 这就是逐字渐变(karaoke)效果, 不需要每帧重建 TextSpan。
class KaraokeLine extends StatefulWidget {
  const KaraokeLine({
    super.key,
    required this.line,
    required this.positionMs,
    required this.sungColor,
    required this.upcomingColor,
    this.playing,
    this.sub,
    this.subColor,
    this.fadeWidth = 8,
  });

  final WordLyricLineData line;

  /// 父级给的采样位置(main 的 120ms ticker / 播放状态回调)。
  final int positionMs;

  final Color sungColor;
  final Color upcomingColor;

  /// 播放中标志; null 视为未播放(不插值)。
  final ValueListenable<bool>? playing;

  final String? sub;
  final Color? subColor;

  /// 右缘软边的渐变宽度(px)。
  final double fadeWidth;

  @override
  State<KaraokeLine> createState() => KaraokeLineState();
}

class KaraokeLineState extends State<KaraokeLine>
    with SingleTickerProviderStateMixin {
  /// 插值后的位置(只驱动重绘, 不 setState)。
  final ValueNotifier<int> _pos = ValueNotifier<int>(0);

  late final Ticker _ticker;

  /// 最近一次 tick 的 elapsed(相对当前 ticker 启动)。
  Duration _now = Duration.zero;
  bool _haveTick = false;

  /// 采样点: 位置 [_samplePos] 对应 ticker 的 [_sampleElapsed]。
  int _samplePos = 0;
  Duration _sampleElapsed = Duration.zero;

  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _samplePos = widget.positionMs;
    _pos.value = _clamp(widget.positionMs);
    _ticker = createTicker(_onTick);
    widget.playing?.addListener(_onPlayingChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant KaraokeLine oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playing != widget.playing) {
      oldWidget.playing?.removeListener(_onPlayingChanged);
      widget.playing?.addListener(_onPlayingChanged);
    }
    if (oldWidget.line != widget.line ||
        oldWidget.positionMs != widget.positionMs ||
        oldWidget.playing != widget.playing) {
      // 收到新的采样位置: 插值基准重置到 (新位置, 当前时刻)
      _samplePos = widget.positionMs;
      if (_haveTick) _sampleElapsed = _now;
      _pos.value = _clamp(widget.positionMs);
    }
    _syncTicker();
  }

  @override
  void dispose() {
    widget.playing?.removeListener(_onPlayingChanged);
    _ticker.dispose();
    _pos.dispose();
    super.dispose();
  }

  int _clamp(int ms) => ms < widget.line.startMs ? widget.line.startMs : ms;

  void _onPlayingChanged() => _syncTicker();

  /// reduce motion / 未播放 / 已唱到本行末尾 时不排帧。
  bool get _wantTicker =>
      !_reduceMotion &&
      (widget.playing?.value ?? false) &&
      _pos.value < widget.line.endMs;

  void _syncTicker() {
    final want = _wantTicker;
    if (want && !_ticker.isActive) {
      _haveTick = false;
      _ticker.start();
    } else if (!want && _ticker.isActive) {
      _ticker.stop();
      _haveTick = false;
    }
  }

  void _onTick(Duration elapsed) {
    if (!_haveTick) {
      _haveTick = true;
      _now = elapsed;
      _sampleElapsed = elapsed;
      return;
    }
    _now = elapsed;
    var ms = _samplePos + (elapsed - _sampleElapsed).inMilliseconds;
    final end = widget.line.endMs;
    if (ms > end) ms = end;
    if (ms < widget.line.startMs) ms = widget.line.startMs;
    if (ms != _pos.value) _pos.value = ms;
    if (ms >= end) {
      _ticker.stop();
      _haveTick = false;
    }
  }

  /// 测试用: 是否正在本地插值(排帧)。
  @visibleForTesting
  bool get debugInterpolating => _ticker.isActive;

  /// 测试用: 当前用于绘制的插值位置。
  @visibleForTesting
  int get debugPositionMs => _pos.value;

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final text = karaokeLineText(widget.line);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth.isFinite
                  ? constraints.maxWidth
                  : 320.0;
              final layout = _layoutFor(
                text: text,
                words: widget.line.words,
                maxWidth: maxWidth,
                scaler: scaler,
                direction: direction,
                baseColor: widget.upcomingColor,
                sungColor: widget.sungColor,
              );
              return Semantics(
                label: text,
                child: SizedBox(
                  width: maxWidth,
                  height: layout.size.height,
                  child: CustomPaint(
                    size: Size(maxWidth, layout.size.height),
                    isComplex: true,
                    willChange: true,
                    painter: KaraokePainter(
                      line: widget.line,
                      position: _pos,
                      sungColor: widget.sungColor,
                      upcomingColor: widget.upcomingColor,
                      style: karaokeActiveTextStyle,
                      textScaler: scaler,
                      textDirection: direction,
                      fadeWidth: widget.fadeWidth,
                    ),
                  ),
                ),
              );
            },
          ),
          if (widget.sub != null)
            Text(
              widget.sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: widget.subColor),
            ),
        ],
      ),
    );
  }
}

/// 一行的文本排版结果(底层/顶层两份 TextPainter 共用同一套几何)。
class _KaraokeLayout {
  _KaraokeLayout({
    required this.base,
    required this.sung,
    required this.wordRects,
  });

  final TextPainter base;
  final TextPainter sung;

  /// 每个词的矩形(多 box 取 union); 被 ellipsis 截掉的词为 null。
  final List<Rect?> wordRects;

  Size get size => base.size;
}

/// 小容量 LRU: 同一行文本 + 宽度 + 样式在多次重绘间复用排版结果。
final Map<String, _KaraokeLayout> _layoutCache = <String, _KaraokeLayout>{};
const int _layoutCacheMax = 8;

_KaraokeLayout _layoutFor({
  required String text,
  required List<WordLyricWord> words,
  required double maxWidth,
  required TextScaler scaler,
  required TextDirection direction,
  required Color baseColor,
  required Color sungColor,
}) {
  final key =
      '$text|$maxWidth|${scaler.scale(karaokeFontSize)}|${direction.name}'
      '|${karaokeActiveTextStyle.fontSize}|${karaokeActiveTextStyle.fontWeight}'
      '|${baseColor.toARGB32()}|${sungColor.toARGB32()}';
  final hit = _layoutCache.remove(key);
  if (hit != null) {
    _layoutCache[key] = hit; // LRU touch
    return hit;
  }
  TextPainter build(Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: karaokeActiveTextStyle.copyWith(color: color),
    ),
    textDirection: direction,
    textScaler: scaler,
    textAlign: TextAlign.center,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);

  final base = build(baseColor);
  final sung = build(sungColor);
  final rects = <Rect?>[];
  var offset = 0;
  for (final w in words) {
    final start = offset;
    final end = offset + w.text.length;
    offset = end;
    if (end <= start) {
      rects.add(null);
      continue;
    }
    final boxes = base.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: end),
    );
    if (boxes.isEmpty) {
      rects.add(null);
      continue;
    }
    var r = Rect.fromLTRB(
      boxes.first.left,
      boxes.first.top,
      boxes.first.right,
      boxes.first.bottom,
    );
    for (final b in boxes.skip(1)) {
      r = r.expandToInclude(Rect.fromLTRB(b.left, b.top, b.right, b.bottom));
    }
    rects.add(r);
  }
  final layout = _KaraokeLayout(base: base, sung: sung, wordRects: rects);
  if (_layoutCache.length >= _layoutCacheMax) {
    _layoutCache.remove(_layoutCache.keys.first);
  }
  _layoutCache[key] = layout;
  return layout;
}

/// 逐字渐变歌词的画笔: 底层全行未唱色 + 顶层已唱色按裁切矩形绘制。
@visibleForTesting
class KaraokePainter extends CustomPainter {
  KaraokePainter({
    required this.line,
    required this.position,
    required this.sungColor,
    required this.upcomingColor,
    required this.style,
    required this.textScaler,
    required this.textDirection,
    this.fadeWidth = 8,
  }) : super(repaint: position);

  final WordLyricLineData line;

  /// 插值后的位置; 作为 `repaint` 驱动重绘(不触发 rebuild)。
  final ValueListenable<int> position;

  final Color sungColor;
  final Color upcomingColor;
  final TextStyle style;
  final TextScaler textScaler;
  final TextDirection textDirection;
  final double fadeWidth;

  /// 上一次绘制用的裁切矩形(画布坐标), 供测试断言。
  @visibleForTesting
  List<Rect> debugClipRects = const <Rect>[];

  /// 上一次绘制时最后一个裁切矩形的宽度(当前词已亮的宽度)。
  @visibleForTesting
  double get debugLeadingClipWidth =>
      debugClipRects.isEmpty ? 0 : debugClipRects.last.width;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) {
      debugClipRects = const <Rect>[];
      return;
    }
    final text = karaokeLineText(line);
    final layout = _layoutFor(
      text: text,
      words: line.words,
      maxWidth: size.width,
      scaler: textScaler,
      direction: textDirection,
      baseColor: upcomingColor,
      sungColor: sungColor,
    );
    final rawDy = (size.height - layout.size.height) / 2;
    final offset = Offset(0, rawDy < 0 ? 0 : rawDy);
    // 底层: 整行未唱色
    layout.base.paint(canvas, offset);

    final styles = wordStylesAt(line, position.value);
    var rects = karaokeClipRects(
      styles,
      layout.wordRects,
    ).map((r) => r.shift(offset)).toList(growable: false);
    if (rects.isEmpty &&
        line.words.isEmpty &&
        styles.length == 1 &&
        styles.first.state == WordHighlightState.current) {
      // 无词时间的整行: 视为一句整体已唱
      rects = [
        Rect.fromLTWH(0, offset.dy, layout.size.width, layout.size.height),
      ];
    }
    debugClipRects = rects;
    if (rects.isEmpty) return;

    final path = Path();
    for (final r in rects) {
      path.addRect(r);
    }
    canvas.save();
    canvas.saveLayer(path.getBounds().inflate(2), Paint());
    canvas.clipPath(path);
    // 顶层: 已唱色(裁切到已唱区域)
    layout.sung.paint(canvas, offset);

    // 右缘软边: 当前词推进沿 ±fadeWidth/2 的线性渐变遮罩
    var currentIdx = -1;
    for (var i = 0; i < styles.length; i++) {
      if (styles[i].state == WordHighlightState.current) {
        currentIdx = i;
        break;
      }
    }
    if (currentIdx >= 0 &&
        styles[currentIdx].progress < 1 &&
        currentIdx < layout.wordRects.length) {
      final wr = layout.wordRects[currentIdx];
      if (wr != null && wr.width > 0) {
        final band = Rect.fromLTRB(
          wr.right - fadeWidth / 2,
          wr.top,
          wr.right + fadeWidth / 2 + 0.5,
          wr.bottom,
        ).shift(offset);
        final gradient = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [Color(0xFFFFFFFF), Color(0x00FFFFFF)],
        ).createShader(band);
        canvas.drawRect(
          band,
          Paint()
            ..blendMode = BlendMode.dstIn
            ..shader = gradient,
        );
      }
    }
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(KaraokePainter oldDelegate) =>
      oldDelegate.line != line ||
      oldDelegate.position != position ||
      oldDelegate.sungColor != sungColor ||
      oldDelegate.upcomingColor != upcomingColor ||
      oldDelegate.style != style ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.textDirection != textDirection ||
      oldDelegate.fadeWidth != fadeWidth;

  @override
  bool shouldRebuildSemantics(KaraokePainter oldDelegate) => false;
}

class _LineBody extends StatelessWidget {
  const _LineBody({
    required this.main,
    required this.sub,
    required this.subColor,
  });

  final InlineSpan main;
  final String? sub;
  final Color subColor;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            text: main,
          ),
          if (sub != null)
            Text(
              sub!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: subColor),
            ),
        ],
      ),
    );
  }
}
