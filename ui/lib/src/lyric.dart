import 'package:flutter/material.dart';

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

final RegExp _timeTag = RegExp(r'^(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?$');

/// 把 `[mm:ss]` / `[mm:ss.xx]` / `[mm:ss.xxx]` 解析成毫秒; 不是合法时间标签返回 null。
/// 小数位不足 3 位按右补零处理(.5 → 500ms, .50 → 500ms)。
BigInt? _parseTimeTag(String tag) {
  final m = _timeTag.firstMatch(tag);
  if (m == null) return null;
  final minutes = int.parse(m.group(1)!);
  final seconds = int.parse(m.group(2)!);
  final fracRaw = m.group(3);
  var fracMs = 0;
  if (fracRaw != null) {
    final padded = fracRaw.padRight(3, '0');
    fracMs = int.parse(padded);
  }
  return BigInt.from(minutes * 60000 + seconds * 1000 + fracMs);
}

/// 解析 LRC 文本。设计目标是不崩、不空白:
/// - 行首方括号标签逐个剥离; 合法时间标签收集为时间轴, 一行多标签展开成多行;
/// - 剥完后没有时间标签的行进 [LyricDoc.plain](元数据行如 `[ti:...]`、空行、
///   剥完只剩空串的行直接丢弃);
/// - 格式异常的标签(`[00:xx]`、`[abc]`、截断的 `[01:0` 等)不会抛异常:
///   剩下的文字按纯文本保留, 什么都剩不下就丢掉该行;
/// - [translations] 是 tlyric 按毫秒对齐的翻译表; 缺失或没有对应行时
///   [ParsedLyricLine.sub] 为 null, 展示层必须容忍翻译缺失。
LyricDoc parseLrc(String raw, {Map<BigInt, String>? translations}) {
  final timed = <ParsedLyricLine>[];
  final plain = <String>[];
  for (var line in raw.split('\n')) {
    line = line.trim();
    if (line.isEmpty) continue;
    final times = <BigInt>[];
    var rest = line;
    // 剥掉行首所有方括号标签(时间标签进 times, 其余丢弃)
    while (rest.startsWith('[')) {
      final close = rest.indexOf(']');
      if (close < 0) break; // 截断的标签, 当普通文本处理
      final tag = rest.substring(1, close);
      final ms = _parseTimeTag(tag);
      if (ms != null) {
        times.add(ms);
      }
      // 无论标签合不合法都从行首剥掉, 文字部分另行处理
      rest = rest.substring(close + 1).trim();
    }
    if (rest.isEmpty) continue; // 纯标签行(元数据/间奏)或剥完什么都不剩
    if (times.isNotEmpty) {
      for (final t in times) {
        timed.add(ParsedLyricLine(timeMs: t, text: rest, sub: translations?[t]));
      }
    } else {
      plain.add(rest);
    }
  }
  timed.sort((a, b) => a.timeMs.compareTo(b.timeMs));
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
  });

  final List<String> lines;
  final String emptyText;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return Center(child: Text(emptyText));
    }
    final scheme = Theme.of(context).colorScheme;
    return ListView.builder(
      padding: padding ?? const EdgeInsets.symmetric(vertical: 24, horizontal: 20),
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final line = lines[i];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            line.trim().isEmpty ? '♪' : line,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}
