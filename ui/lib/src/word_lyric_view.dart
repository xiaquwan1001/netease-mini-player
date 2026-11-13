import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 逐字(karaoke)歌词的纯展示组件。
///
/// 设计约束:
/// - **不拉 FFI、不读全局单例**: 数据([WordLyricLineData])与播放位置
///   (positionMs, `ValueListenable<int>` 毫秒)全部由调用方注入, 可在 widget
///   test 里直接 pump 驱动;
/// - 位置 tick 只重建**当前行**(其余行是静态 Text, 且各行有 RepaintBoundary),
///   行下标变化时最多重建两行, 不会整页 setState;
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
/// - 相邻且竖直对齐(容差 0.5px)的矩形会合并成一个, 避免逐词 clip 留下接缝、
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
    this.controller,
    this.itemExtent = 56,
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

  final ScrollController? controller;
  final double itemExtent;
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
    final target =
        idx * widget.itemExtent -
        (position.viewportDimension - widget.itemExtent) / 2;
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
        itemExtent: widget.itemExtent,
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
                        builder: (context, pos, _) => _ActiveWordLine(
                          line: line,
                          positionMs: pos,
                          scheme: scheme,
                          isSelected: isSelected,
                          showTranslation: widget.showTranslation,
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
    final text = line.words.isEmpty
        ? '♪'
        : [for (final w in line.words) w.text].join();
    return _LineBody(
      main: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: 15,
          color: isSelected ? scheme.onSurface : scheme.onSurfaceVariant,
          fontWeight: FontWeight.w400,
        ),
      ),
      sub: showTranslation ? line.sub : null,
      subColor: scheme.outline,
    );
  }
}

class _ActiveWordLine extends StatelessWidget {
  const _ActiveWordLine({
    required this.line,
    required this.positionMs,
    required this.scheme,
    this.isSelected = false,
    this.showTranslation = true,
  });

  final WordLyricLineData line;
  final int positionMs;
  final ColorScheme scheme;
  final bool isSelected;
  final bool showTranslation;

  @override
  Widget build(BuildContext context) {
    final styles = wordStylesAt(line, positionMs);
    final sung = scheme.primary;
    final upcoming = scheme.onSurfaceVariant.withValues(alpha: 0.55);
    return _LineBody(
      main: TextSpan(
        children: [
          for (final s in styles)
            TextSpan(
              text: s.text,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: s.state == WordHighlightState.upcoming ? upcoming : sung,
              ),
            ),
        ],
      ),
      sub: showTranslation ? line.sub : null,
      subColor: scheme.primary.withValues(alpha: 0.8),
    );
  }
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
