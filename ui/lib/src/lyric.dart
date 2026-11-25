import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'layout.dart' show rowExtentFor;
import 'marquee_text.dart' show MarqueePlayGate, MarqueeText;

/// 歌词时间轴的小工具(纯逻辑, 便于单测).
///
/// UI 只需要两个问题的答案: 当前该高亮哪一行、下一行在哪 —— 都在这里。
///
/// 规则:
/// - 返回值为 [0, times.length) 的下标; -1 表示播放位置还没到第一句;
/// - `times` 必须升序(解析层已排序)。
int lyricIndexAt(List<BigInt> timesMs, BigInt positionMs) {
  var lo = 0;
  var hi = timesMs.length - 1;
  var found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (timesMs[mid] <= positionMs) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return found;
}

// ---------------- LRC 解析(B0: 纯文本歌词备用展示) ----------------
//
// **与 `core/crates/ncm-domain/src/lrc.rs`(权威实现)同口径, 改动需同步两侧。**
// 正常路径走 Rust(`rust.lyricLinesI18N`, 见 `home/lyric_controller.dart`); 这里只兜底
// 逐行接口失败/为空时从原始 LRC 里抢回内容, 但同一首歌在两条路径上必须得到同一个时间轴,
// 否则兜底一回歌词就会整体错位。已对齐的三条: `[offset:±ms]` 整体位移、
// 按 `(时间, 文本)` 去重、小数只取前 3 位(`.1234` = 123ms, 不是 1234ms)。
// 已知的**刻意**差异只有一条: 无时间标签的行这里保留为纯文本(Rust 直接丢掉),
// 因为兜底路径要能展示“只有纯文本的老歌词”。

/// 一行解析结果: 文本 + 可选翻译([sub], 来自 tlyric, 缺失时为 null)。
class ParsedLyricLine {
  const ParsedLyricLine({required this.timeMs, required this.text, this.sub});

  final BigInt timeMs;
  final String text;
  final String? sub;
}

/// [parseLrc] 的结果:
/// - [hasTimeline]: 有逐行时间轴, 用 [timed](已按 timeMs 升序)驱动高亮滚动;
/// - 无时间轴且 [plain] 非空: 只有纯文本, 调用方用 [PlainLyricView] 按行展示;
/// - [isEmpty]: 完全没有可用内容, 调用方显示空态(如「暂无歌词」)。
class LyricDoc {
  const LyricDoc({this.timed = const [], this.plain = const []});

  final List<ParsedLyricLine> timed;
  final List<String> plain;

  bool get hasTimeline => timed.isNotEmpty;
  bool get isEmpty => !hasTimeline && plain.isEmpty;
}

final RegExp _timeTag = RegExp(r'^(\d{1,3}):(\d{1,2})(?:[.:](\d+))?$');

/// `[offset:±ms]` 标签的前缀(元信息行, 不进歌词行)
const String _offsetTag = 'offset:';

/// 把 `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]` 解析成毫秒; 不是合法时间标签返回 null。
///
/// 与 Rust `parse_time_tag` 同口径:
/// - 秒 >= 60 视为非法标签(`[00:99.00]` 不猜成“1 分 39 秒”);
/// - 小数只取**前 3 位**(`.1234` → 123ms); 不足 3 位按位权放大(`.5` → 500ms)。
BigInt? _parseTimeTag(String tag) {
  final m = _timeTag.firstMatch(tag);
  if (m == null) return null;
  final minutes = int.parse(m.group(1)!);
  final seconds = int.parse(m.group(2)!);
  if (seconds >= 60) return null;
  final fracRaw = m.group(3);
  var fracMs = 0;
  if (fracRaw != null && fracRaw.isNotEmpty) {
    final digits = fracRaw.length > 3 ? fracRaw.substring(0, 3) : fracRaw;
    final v = int.parse(digits);
    fracMs = switch (digits.length) {
      1 => v * 100,
      2 => v * 10,
      _ => v,
    };
  }
  return BigInt.from(minutes * 60000 + seconds * 1000 + fracMs);
}

/// 应用 `[offset:±ms]`(正数 = 歌词提前), 与 Rust 一样不允许负时间。
BigInt _applyOffset(BigInt timeMs, int offsetMs) {
  if (offsetMs == 0) return timeMs;
  final shifted = timeMs - BigInt.from(offsetMs);
  return shifted.isNegative ? BigInt.zero : shifted;
}

/// 解析 LRC 文本。设计目标是不崩、不空白:
/// - 行首方括号标签逐个剥离; 合法时间标签收集为时间轴, 一行多标签展开成多行;
/// - `[offset:±ms]` 整体位移时间轴(正数 = 歌词提前), 位移在去重**之前**生效;
/// - 同一个 `(时间, 文本)` 只保留一条(网易云会返回重复行);
/// - 剥完后没有时间标签的行进 [LyricDoc.plain](元数据行如 `[ti:...]`、空行、
///   剥完只剩空串的行直接丢弃);
/// - 格式异常的标签(`[00:xx]`、`[abc]`、截断的 `[01:0` 等)不会抛异常:
///   剩下的文字按纯文本保留, 什么都剩不下就丢掉该行;
/// - [translations] 是 tlyric 按毫秒对齐的翻译表(键是**位移后**的毫秒); 缺失或没有对应行时
///   [ParsedLyricLine.sub] 为 null, 展示层必须容忍翻译缺失。
LyricDoc parseLrc(String raw, {Map<BigInt, String>? translations}) {
  final stamped = <({BigInt timeMs, String text})>[];
  final plain = <String>[];
  var offsetMs = 0;
  for (var line in raw.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    final times = <BigInt>[];
    var rest = line;
    // 剥掉行首所有方括号标签(时间标签进 times, offset 记账, 其余丢弃)
    while (rest.startsWith('[')) {
      final close = rest.indexOf(']');
      if (close < 0) break; // 截断的标签, 当普通文本处理
      final tag = rest.substring(1, close);
      final ms = _parseTimeTag(tag);
      if (ms != null) {
        times.add(ms);
      } else if (tag.startsWith(_offsetTag)) {
        final v = int.tryParse(tag.substring(_offsetTag.length).trim());
        if (v != null) offsetMs = v;
      }
      // 无论标签合不合法都从行首剥掉, 文字部分另行处理
      rest = rest.substring(close + 1).trim();
    }
    if (rest.isEmpty) continue; // 纯标签行(元数据/间奏)或剥完什么都不剩
    if (times.isEmpty) {
      plain.add(rest);
      continue;
    }
    for (final t in times) {
      stamped.add((timeMs: t, text: rest));
    }
  }

  // 排序按“时间升序 + 原始顺序”做**稳定**排序, 与 Rust `sort_by_key` 同级:
  // 同时刻的不同行保持出现顺序, 兜底与权威路径不会排出两种字序。
  final ordered = [
    for (final (i, s) in stamped.indexed)
      (index: i, timeMs: _applyOffset(s.timeMs, offsetMs), text: s.text),
  ];
  ordered.sort((a, b) {
    final byTime = a.timeMs.compareTo(b.timeMs);
    return byTime != 0 ? byTime : a.index.compareTo(b.index);
  });

  // 去重只去掉**相邻**的完全重复行(排序后即同时间同文本), 与 Rust `dedup_by` 一致
  final timed = <ParsedLyricLine>[];
  for (final line in ordered) {
    if (timed.isNotEmpty) {
      final prev = timed.last;
      if (prev.timeMs == line.timeMs && prev.text == line.text) continue;
    }
    timed.add(
      ParsedLyricLine(
        timeMs: line.timeMs,
        text: line.text,
        sub: translations?[line.timeMs],
      ),
    );
  }
  return LyricDoc(timed: timed, plain: plain);
}

/// 纯文本歌词的备用展示(逐行 LRC 解析失败/只有无时间标签的纯文本时用)。
///
/// 每行独立软换行, 300dp 窄屏 + 1.25 大字号也不会溢出;
/// 空内容显示 [emptyText]; 每行没有翻译(sub), 展示层不允许依赖它。
class PlainLyricView extends StatelessWidget {
  const PlainLyricView({
    super.key,
    required this.lines,
    this.emptyText = '暂无歌词',
    this.padding,
    this.controller,
    this.selected = const <int>{},
    this.onLineTap,
    this.onLineLongPress,
  });

  final List<String> lines;
  final String emptyText;
  final EdgeInsetsGeometry? padding;

  /// 传进来即可支持"定位到当前行"这类外部滚动
  final ScrollController? controller;

  /// 多选状态下选中的行下标(纯文本歌词同样能长按选中分享)
  final Set<int> selected;
  final void Function(int index)? onLineTap;
  final void Function(int index)? onLineLongPress;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return Center(child: Text(emptyText));
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: controller,
      padding:
          padding ?? const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final line = lines[i];
        final isSelected = selected.contains(i);
        return GestureDetector(
          key: ValueKey('plain-lyric-line-$i'),
          behavior: HitTestBehavior.opaque,
          onTap: onLineTap == null ? null : () => onLineTap!(i),
          onLongPress: onLineLongPress == null
              ? null
              : () => onLineLongPress!(i),
          child: Container(
            decoration: isSelected
                ? BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  )
                : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              child: Text(
                line.trim().isEmpty ? '♪' : line,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  color: isSelected
                      ? scheme.onSurface
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 行级歌词字号: 静态行与当前行**几乎同号**(只 +1sp), 与逐字视图
/// (`word_lyric_view.dart` 的 `karaokeFontSize` 口径一致)。
///
/// 历史: 当前行曾是 18sp/w600、静态 15sp —— 播放位置跨行时整行按新字号重排,
/// 用户看到的是「高光行突然变大、像被推到左边」的一次瞬移(2026-11-17 反馈)。
/// 现在只 +1sp 加粗, 且两种行都 `TextAlign.center` 居中, 不再有横向跳动。
const double kTimedLyricFontSize = 15;
const double kTimedLyricActiveFontSize = 16;

/// 行级歌词视图(带时间轴): 当前行高亮 + 翻译开关 + 多选.
///
/// 纯展示组件: 当前行下标/滚动控制/选中集合都由调用方给, 因此能在 widget test
/// 里直接 pump 各种状态; 滚动位置由外部 [controller] 拥有(调用方决定"跟不跟随").
class TimedLyricView extends StatelessWidget {
  const TimedLyricView({
    super.key,
    required this.lines,
    required this.activeIndex,
    this.controller,

    /// 行高; 不传 = [kRowExtent] × 系统字号(见 [rowExtentFor]).
    /// 歌词是 16sp 主词 + 12sp 翻译两行, 写死 56 在 1.625 字号下会被 itemExtent
    /// 从下方裁掉(用户报过"顶部歌词只显示上半段").
    this.itemExtent,
    this.showTranslation = true,
    this.selected = const <int>{},
    this.onLineTap,
    this.onLineLongPress,
    this.playing,
    this.emptyText = '暂无歌词',
    this.padding = const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
  });

  /// 已按 timeMs 升序的行(见 [parseLrc])
  final List<ParsedLyricLine> lines;

  /// 当前高亮行下标; -1 = 还没到第一句
  final int activeIndex;

  final ScrollController? controller;
  final double? itemExtent;

  /// 关掉时整块不渲染翻译行(歌词本身没有翻译时开关也不该出现)
  final bool showTranslation;

  /// 多选状态下选中的行下标
  final Set<int> selected;

  /// 点某一行(多选模式下用来加/减选); 为 null 时点击无反馈
  final void Function(int index)? onLineTap;

  /// 长按某一行(进入多选并选中该行); 为 null 时长按无反馈
  final void Function(int index)? onLineLongPress;

  /// 播放中标志: 只有播放中当前行才横向自动滚动(暂停/静态预览停在行首, 零排帧).
  ///
  /// 为 null 视为未播放 —— 静态场景(测试/概览)不排帧, `pumpAndSettle` 能收敛。
  final ValueListenable<bool>? playing;

  final String emptyText;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return Center(child: Text(emptyText));
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      controller: controller,
      itemExtent: itemExtent ?? rowExtentFor(context),
      padding: padding,
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final line = lines[i];
        final active = i == activeIndex;
        final isSelected = selected.contains(i);
        final text = line.text.isEmpty ? '♪' : line.text;
        final sub = showTranslation ? line.sub : null;
        final style = TextStyle(
          fontSize: active ? kTimedLyricActiveFontSize : kTimedLyricFontSize,
          fontWeight: active ? FontWeight.w600 : FontWeight.w400,
          color: active
              ? scheme.primary
              : (isSelected ? scheme.onSurface : scheme.onSurfaceVariant),
        );
        final body = Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 当前行超宽时横向自动滚动(跑马灯, 与歌名同一实现); 放得下时仍是
            // 居中的静态文本, 所以短句不会有任何位移。
            // 非当前行保持单行省略号: 不能让整页歌词都在动。
            if (!active)
              Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: style,
              )
            else
              MarqueePlayGate(
                playing: playing,
                child: MarqueeText(
                  text,
                  style: style,
                  textAlign: TextAlign.center,
                ),
              ),
            if (sub != null)
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: active
                      ? scheme.primary.withValues(alpha: 0.8)
                      : scheme.outline,
                ),
              ),
          ],
        );
        return GestureDetector(
          key: ValueKey('lyric-line-$i'),
          behavior: HitTestBehavior.opaque,
          onTap: onLineTap == null ? null : () => onLineTap!(i),
          onLongPress: onLineLongPress == null
              ? null
              : () => onLineLongPress!(i),
          child: Container(
            decoration: isSelected
                ? BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  )
                : null,
            child: Center(child: body),
          ),
        );
      },
    );
  }
}
