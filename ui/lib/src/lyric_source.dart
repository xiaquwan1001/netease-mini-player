/// 逐字歌词三来源解析(yrc -> AMLL TTML -> 行级): **只做编排, 不打分**。
///
/// 架构审计 7.3: 打分权重/容差/阈值/择优理由原先在 Dart 与 Rust 各有一份(本文件头
/// 自称"与 Rust 同口径的 Dart 镜像"), 改一处必须改两处, 还各有单测各测各的。现在这些
/// 规则**只有 Rust 一份**(`core/crates/ncm-service/src/ttml_source.rs`), 这里每个判断都
/// 同步问 FFI 要结论: `rust.lyricScore` / `lyricChooseSource` / `lyricAutoSkipTtml` /
/// `lyricYrcGoodEnough` / `lyricScoresClose`。**本文件不许再出现打分数字**。
///
/// 保留的两件事:
/// - loader 注入([LyricSourceLoaders]): 单测换假 loader, 全程不联网;
/// - 三来源编排(按偏好 auto/netease/amll 决定先探谁, 以及什么时候省掉一次 TTML 探测 /
///   一次行级 LRC 请求), 对用户可见行为与下沉前逐分支一致。
library;

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

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

/// ---------------- C2: 打分与择优(实现与阈值都在 Rust, 这里只是转发) ----------------

/// 打分分项与总分(全部 0..1)。**只是 Rust `WordLyricScoreDto` 的本地视图**:
/// 分项公式、权重、容差、阈值全部在 Rust, 这里不许再出现任何数字。
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
  WordLyricScore.fromDto(rust.WordLyricScoreDto d)
    : this(
        d.coverage,
        d.monotonic,
        d.firstWord,
        d.spans,
        d.consistency,
        d.score,
      );
}

/// 逐字歌词质量打分(纯函数, 实现在 Rust)。`lineStarts` 为行级 LRC 各行起始 ms,
/// 无参照时一致性记中性(具体口径见 Rust `score_word_lyric`)。
WordLyricScore scoreWordLyric(rust.WordLyricDto? wl, {List<int>? lineStarts}) =>
    WordLyricScore.fromDto(
      rust.lyricScore(dto: wl, lineStarts: _lineStarts(lineStarts)),
    );

/// yrc 是否"足够好"(netease 偏好口径: 有行、有词级时间、覆盖率达标; 阈值在 Rust)。
bool yrcWordGoodEnough(rust.WordLyricDto? wl) =>
    wl != null && rust.lyricYrcGoodEnough(dto: wl);

/// auto 择优纯函数: 两来源都在时选高分者并给出短理由; 只有一方直接选它(理由 null)。
({String? source, String? reason}) chooseWordSource(
  rust.WordLyricDto? yrc,
  rust.WordLyricDto? ttml, {
  List<int>? lineStarts,
}) {
  final choice = rust.lyricChooseSource(
    yrc: yrc,
    ttml: ttml,
    lineStarts: _lineStarts(lineStarts),
  );
  return (source: choice.source, reason: choice.reason);
}

/// 行级起始时间 -> FFI 用的定长数组(空 = 无参照)。
Int64List _lineStarts(List<int>? lineStarts) =>
    lineStarts == null || lineStarts.isEmpty
    ? Int64List(0)
    : Int64List.fromList(lineStarts);

/// 来源小字标注文案(纯函数, 单测覆盖)。短文案: "逐字歌词 · AMLL(择优: yrc 时间错乱)"。
/// 文案属 UI 口径(不是打分规则), 留在 Dart。
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
  // netease: 旧口径(覆盖率达标即算够好, 阈值在 Rust), 够好就直接用
  if (preference == 'netease') {
    if (yrcWordGoodEnough(yrc)) return ResolvedLyric.word_(yrc!);
    final ttml = await loadTtml();
    if (ttml != null) return ResolvedLyric.ttml_(ttml);
    if (yrc != null && yrc.lines.isNotEmpty) return ResolvedLyric.word_(yrc);
    return _lineLevel(trackId, loaders);
  }

  // auto: 打分择优; yrc 得分已很高就不必请求 TTML(避免无谓网络)
  if (yrc != null && rust.lyricAutoSkipTtml(dto: yrc)) {
    return ResolvedLyric.word_(yrc);
  }
  final ttml = await loadTtml();
  if (yrc != null || ttml != null) {
    List<int>? lineStarts;
    // 得分接近时才取行级 LRC 起始时间做一致性加分(可注入 loader, 不额外打无谓网络)
    if (yrc != null &&
        ttml != null &&
        rust.lyricScoresClose(yrc: yrc, ttml: ttml)) {
      try {
        final line = await loaders.lineLevel(trackId);
        lineStarts = line?.map((l) => l.timeMs.toInt()).toList();
      } catch (_) {}
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
