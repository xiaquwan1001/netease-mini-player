/// 逐字歌词三来源解析(yrc -> AMLL TTML -> 行级)与打分择优(与 Rust 同口径)。
///
/// 从 `main.dart` 原样搬出(B13 + C2 两段), 只搬运不改行为: `resolveLyricSource`
/// 按偏好 auto/netease/amll 决定先探哪个来源, `scoreWordLyric`/`chooseWordSource`
/// 是 Rust `ncm_service::ttml_source` 的 Dart 镜像。
library;

import 'rust/api.dart' as rust;

/// ---------------- B13: 逐字歌词三来源解析(yrc -> AMLL TTML -> 行级) ----------------

/// 三个来源的 loader 抽象: 生产环境包 rust.* 调用, 单测注入假实现(不联网)。
class LyricSourceLoaders {
  final Future<rust.WordLyricDto?> Function(BigInt trackId) yrc;
  final Future<rust.WordLyricDto?> Function(BigInt trackId) ttml;
  final Future<List<rust.LyricLineDto>?> Function(BigInt trackId) lineLevel;
  const LyricSourceLoaders({
    required this.yrc,
    required this.ttml,
    required this.lineLevel,
  });
}

/// 解析结果: word = 逐字数据(来源 yrc/ttml), line = 行级兜底, source 给小字标注,
/// reason 为 auto 择优理由(仅两来源比较后才有, 标注显示"择优: ...")。
class ResolvedLyric {
  final rust.WordLyricDto? word;
  final List<rust.LyricLineDto>? line;
  final String source;
  final String? reason;
  const ResolvedLyric.word_(this.word, {this.reason})
    : line = null,
      source = 'yrc';
  const ResolvedLyric.ttml_(this.word, {this.reason})
    : line = null,
      source = 'ttml';
  const ResolvedLyric.line_(this.line)
    : word = null,
      source = 'line',
      reason = null;
}

/// yrc 逐字行覆盖率: 有词级时间(end > start)的行占比. 与 Rust
/// ncm_service::ttml_source::yrc_word_coverage 同口径, 阈值 0.6(六成行是逐字才算合格)。
const double kYrcWordCoverageThreshold = 0.6;

bool yrcWordGoodEnough(rust.WordLyricDto? wl) {
  if (wl == null || wl.lines.isEmpty || !wl.hasWordTiming) return false;
  final covered = wl.lines
      .where((l) => l.words.any((w) => w.endMs > w.startMs))
      .length;
  return covered / wl.lines.length >= kYrcWordCoverageThreshold;
}

/// ---------------- C2: 打分择优(与 Rust ncm_service::ttml_source 同口径的 Dart 镜像) ----------------

/// auto 模式 yrc 得分 >= 此值即直接用, 不再探测 TTML(省一次网络)。
const double kAutoSkipTtmlScore = 0.9;

/// 打分权重: 覆盖率/时间单调/首字贴行首/每行粒度/与行级 LRC 一致性(和为 1)。
const List<double> kScoreWeights = [0.3, 0.2, 0.15, 0.15, 0.2];
const int _kMonotonicToleranceMs = 50;
const int _kFirstWordToleranceMs = 80;
const int _kLineConsistencyMs = 250;

/// 打分分项与总分(全部 0..1)。与 Rust score_word_lyric 保持同一口径。
class WordLyricScore {
  final double coverage, monotonic, firstWord, spans, consistency, score;
  const WordLyricScore(
    this.coverage,
    this.monotonic,
    this.firstWord,
    this.spans,
    this.consistency,
    this.score,
  );
}

/// 逐字歌词质量打分(纯函数). lineStarts 为行级 LRC 各行起始 ms, 无参照时一致性记 1(中性)。
WordLyricScore scoreWordLyric(rust.WordLyricDto? wl, {List<int>? lineStarts}) {
  if (wl == null || wl.lines.isEmpty) {
    return const WordLyricScore(0, 0, 0, 0, 0, 0);
  }
  final timed = wl.lines
      .where((l) => l.words.any((w) => w.endMs > w.startMs))
      .toList();
  final coverage = timed.length / wl.lines.length;
  double monotonicOf() {
    if (timed.length <= 1) return 1.0;
    var ok = 0;
    for (var i = 1; i < timed.length; i++) {
      if (timed[i].startMs >= timed[i - 1].startMs - _kMonotonicToleranceMs) {
        ok++;
      }
    }
    return ok / (timed.length - 1);
  }

  final monotonic = monotonicOf();
  final firstWord = timed.isEmpty
      ? 0.0
      : timed
                .where(
                  (l) =>
                      (l.words.first.startMs - l.startMs).abs() <=
                      _kFirstWordToleranceMs,
                )
                .length /
            timed.length;
  final spans = timed.isEmpty
      ? 0.0
      : (timed.map((l) => l.words.length).reduce((a, b) => a + b) /
                timed.length /
                2.0)
            .clamp(0.0, 1.0);
  final consistency = (lineStarts == null || lineStarts.isEmpty)
      ? 1.0
      : wl.lines
                .where(
                  (l) => lineStarts.any(
                    (s) => (l.startMs - s).abs() < _kLineConsistencyMs,
                  ),
                )
                .length /
            wl.lines.length;
  final w = kScoreWeights;
  final score =
      w[0] * coverage +
      w[1] * monotonic +
      w[2] * firstWord +
      w[3] * spans +
      w[4] * consistency;
  return WordLyricScore(
    coverage,
    monotonic,
    firstWord,
    spans,
    consistency,
    score,
  );
}

/// auto 择优纯函数: 两来源都在时选高分者并给出短理由; 只有一方直接选它(理由 null)。
({String? source, String? reason}) chooseWordSource(
  rust.WordLyricDto? yrc,
  rust.WordLyricDto? ttml, {
  List<int>? lineStarts,
}) {
  final hasY = yrc != null && yrc.lines.isNotEmpty;
  final hasT = ttml != null && ttml.lines.isNotEmpty;
  if (!hasY && !hasT) return (source: null, reason: null);
  if (hasY && !hasT) return (source: 'yrc', reason: null);
  if (!hasY && hasT) return (source: 'ttml', reason: null);
  final sy = scoreWordLyric(yrc, lineStarts: lineStarts);
  final st = scoreWordLyric(ttml, lineStarts: lineStarts);
  if (sy.score >= st.score) return (source: 'yrc', reason: 'yrc 质量更优');
  final String reason;
  if (sy.monotonic < 0.5) {
    reason = 'yrc 时间错乱';
  } else if (sy.coverage < kYrcWordCoverageThreshold) {
    reason = 'yrc 覆盖低';
  } else if (sy.firstWord < 0.5) {
    reason = 'yrc 首字偏移';
  } else if (sy.spans < st.spans) {
    reason = 'yrc 粒度差';
  } else {
    reason = 'TTML 得分更高';
  }
  return (source: 'ttml', reason: reason);
}

/// 来源小字标注文案(纯函数, 单测覆盖)。短文案: "逐字歌词 · AMLL(择优: yrc 时间错乱)"。
String lyricSourceLabel(String? source, String? reason) {
  if (source == null) return '';
  final base = switch (source) {
    'yrc' => '逐字歌词 · 网易云',
    'ttml' => '逐字歌词 · AMLL',
    _ => '逐行歌词',
  };
  if (reason == null || source == 'line') return base;
  return '$base(择优: $reason)';
}

/// 三来源决策(按偏好 auto/netease/amll). 任一来源抛错都当作"该来源没有",
/// 继续回退, 绝不上抛。
Future<ResolvedLyric?> resolveLyricSource(
  BigInt trackId,
  LyricSourceLoaders loaders, {
  String preference = 'auto',
}) async {
  Future<rust.WordLyricDto?> loadYrc() async {
    try {
      return await loaders.yrc(trackId);
    } catch (_) {
      return null;
    }
  }

  Future<rust.WordLyricDto?> loadTtml() async {
    try {
      final t = await loaders.ttml(trackId);
      return (t == null || t.lines.isEmpty) ? null : t;
    } catch (_) {
      return null;
    }
  }

  // amll(默认): TTML 优先, 失败再 yrc。两路**并发**发起 —— 串行时 TTML 超时
  // (5s)会先白等一轮才轮到 yrc, 表现为"切歌后歌词好一会儿不出现"。
  if (preference == 'amll') {
    final ttmlFuture = loadTtml();
    final yrcFuture = loadYrc();
    final ttml = await ttmlFuture;
    if (ttml != null) return ResolvedLyric.ttml_(ttml);
    final yrc = await yrcFuture;
    if (yrc != null && yrc.lines.isNotEmpty) return ResolvedLyric.word_(yrc);
    return _lineLevel(trackId, loaders);
  }

  final yrc = await loadYrc();
  // netease: 旧口径(0.6 覆盖率阈值), 够好就直接用
  if (preference == 'netease') {
    if (yrcWordGoodEnough(yrc)) return ResolvedLyric.word_(yrc);
    final ttml = await loadTtml();
    if (ttml != null) return ResolvedLyric.ttml_(ttml);
    if (yrc != null && yrc.lines.isNotEmpty) return ResolvedLyric.word_(yrc);
    return _lineLevel(trackId, loaders);
  }

  // auto: 打分择优; yrc 得分已很高就不必请求 TTML(避免无谓网络)
  if (yrc != null && yrc.lines.isNotEmpty) {
    final sy = scoreWordLyric(yrc);
    if (sy.score >= kAutoSkipTtmlScore) return ResolvedLyric.word_(yrc);
  }
  final ttml = await loadTtml();
  if (yrc != null || ttml != null) {
    List<int>? lineStarts;
    // 得分接近时才取行级 LRC 起始时间做一致性加分(可注入 loader, 不额外打无谓网络)
    if (yrc != null && ttml != null) {
      final sy = scoreWordLyric(yrc);
      final st = scoreWordLyric(ttml);
      if ((sy.score - st.score).abs() < 0.15) {
        try {
          final line = await loaders.lineLevel(trackId);
          lineStarts = line?.map((l) => l.timeMs.toInt()).toList();
        } catch (_) {}
      }
    }
    final choice = chooseWordSource(yrc, ttml, lineStarts: lineStarts);
    if (choice.source == 'ttml' && ttml != null) {
      return ResolvedLyric.ttml_(ttml, reason: choice.reason);
    }
    if (choice.source == 'yrc' && yrc != null && yrc.lines.isNotEmpty) {
      return ResolvedLyric.word_(yrc, reason: choice.reason);
    }
  }
  // yrc 差但非空且 TTML 没有: 仍比行级好
  if (yrc != null && yrc.lines.isNotEmpty) return ResolvedLyric.word_(yrc);
  return _lineLevel(trackId, loaders);
}

Future<ResolvedLyric?> _lineLevel(
  BigInt trackId,
  LyricSourceLoaders loaders,
) async {
  try {
    final line = await loaders.lineLevel(trackId);
    if (line != null && line.isNotEmpty) return ResolvedLyric.line_(line);
  } catch (_) {}
  return null;
}
