// 歌词打分/择优的**数值 + 理由**回归: 唯一事实源在 Rust(架构审计 7.3).
//
// 以前这些断言写在 lyric_source_fallback/preference_test 里, 守的是一份 Dart 镜像;
// 镜像下沉到 Rust 之后, 数值口径由本文件用**真实 Rust 纯函数**锁住(loader 仍是
// 内存假实现, 不联网)。需要本机编好的 cdylib:
//   cargo build -p ncm_ffi --manifest-path core/Cargo.toml
// CI 的 flutter job 只跑 dart、不编 Rust ⇒ 缺库时整组 skip; 同一批数值在
// `cargo test -p ncm-service ttml_source` 里有等价断言, 不会失去覆盖。
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';

final File _libFile = File(
  '${Directory.current.path}/../core/target/debug/libncm_ffi.so',
);
final String? _skip = _libFile.existsSync()
    ? null
    : '缺 core/target/debug/libncm_ffi.so(先 cargo build -p ncm_ffi --manifest-path core/Cargo.toml)';

rust.WordLyricDto _good(
  int lines, {
  int offsetMs = 0,
  int firstWordShiftMs = 0,
}) => rust.WordLyricDto(
  lines: [
    for (var i = 0; i < lines; i++)
      rust.WordLyricLineDto(
        startMs: offsetMs + i * 1000,
        endMs: offsetMs + i * 1000 + 900,
        words: [
          rust.WordItemDto(
            startMs: offsetMs + i * 1000 + firstWordShiftMs,
            endMs: offsetMs + i * 1000 + 400,
            text: '你',
          ),
          rust.WordItemDto(
            startMs: offsetMs + i * 1000 + 400,
            endMs: offsetMs + i * 1000 + 900,
            text: '好',
          ),
        ],
      ),
  ],
  translationLines: const [],
  hasWordTiming: true,
);

/// 行首时间错乱的 yrc(覆盖率高但单调性塌了)。
rust.WordLyricDto _scrambled(int lines) {
  final starts = [9000, 2000, 7000, 4000];
  return rust.WordLyricDto(
    lines: [
      for (var i = 0; i < lines; i++)
        rust.WordLyricLineDto(
          startMs: starts[i],
          endMs: starts[i] + 900,
          words: [
            rust.WordItemDto(
              startMs: starts[i],
              endMs: starts[i] + 400,
              text: '你',
            ),
          ],
        ),
    ],
    translationLines: const [],
    hasWordTiming: true,
  );
}

rust.WordLyricDto _degenerate(int lines) => rust.WordLyricDto(
  lines: [
    for (var i = 0; i < lines; i++)
      rust.WordLyricLineDto(
        startMs: i * 1000,
        endMs: i * 1000,
        words: [rust.WordItemDto(startMs: 0, endMs: 0, text: '整行$i')],
      ),
  ],
  translationLines: const [],
  hasWordTiming: false,
);

void main() {
  setUpAll(() async {
    if (_skip != null) return;
    await RustLib.init(externalLibrary: ExternalLibrary.open(_libFile.path));
  });

  test('scoreWordLyric: 完好 yrc 满分, 退化/空/无数据低分', () {
    final s = scoreWordLyric(_good(3));
    expect(s.coverage, closeTo(1.0, 1e-9));
    expect(s.monotonic, closeTo(1.0, 1e-9));
    expect(s.score, closeTo(1.0, 1e-9));
    final sd = scoreWordLyric(_degenerate(1));
    expect(sd.coverage, 0.0);
    expect(sd.spans, 0.0);
    expect(sd.score, lessThan(0.6));
    final empty = scoreWordLyric(
      rust.WordLyricDto(
        lines: const [],
        translationLines: const [],
        hasWordTiming: false,
      ),
    );
    expect(empty.score, 0.0);
    expect(scoreWordLyric(null).score, 0.0);
  });

  test('打分口径: 行级 LRC 一致性只用 250ms 窗口内的行', () {
    final yrc = _good(2);
    expect(scoreWordLyric(yrc, lineStarts: const [0, 1000]).consistency, 1.0);
    expect(scoreWordLyric(yrc, lineStarts: const [400, 1400]).consistency, 0.0);
  });

  test('chooseWordSource: yrc 覆盖率高但时间错乱应输给 TTML(理由 yrc 时间错乱)', () {
    final c = chooseWordSource(_scrambled(4), _good(4));
    expect(c.source, 'ttml');
    expect(c.reason, 'yrc 时间错乱');
  });

  test('chooseWordSource: 只有一方时不带择优理由, 空的 yrc 等于没有', () {
    expect(chooseWordSource(_good(2), null).source, 'yrc');
    expect(chooseWordSource(_good(2), null).reason, isNull);
    final onlyTtml = chooseWordSource(null, _good(2));
    expect(onlyTtml.source, 'ttml');
    expect(onlyTtml.reason, isNull);
    const emptyYrcDto = rust.WordLyricDto(
      lines: [],
      translationLines: [],
      hasWordTiming: false,
    );
    final emptyYrc = chooseWordSource(emptyYrcDto, _good(2));
    expect(emptyYrc.source, 'ttml');
    expect(emptyYrc.reason, isNull);
    expect(chooseWordSource(null, null).source, isNull);
  });

  test('yrcWordGoodEnough: 覆盖率 0.6 阈值口径', () {
    expect(yrcWordGoodEnough(null), false);
    expect(yrcWordGoodEnough(_good(3)), true);
    expect(yrcWordGoodEnough(_degenerate(3)), false);
  });

  test('auto: yrc 得分已很高(>= 0.9)时跳过 TTML 探测(省一次网络)', () async {
    var ttmlCalls = 0;
    final r = await resolveLyricSource(
      BigInt.one,
      LyricSourceLoaders(
        yrc: (_) async => _good(3),
        ttml: (_) async {
          ttmlCalls++;
          throw StateError('不应探测 TTML');
        },
        lineLevel: (_) async => throw StateError('不应调行级'),
      ),
    );
    expect(r?.source, 'yrc');
    expect(r?.reason, isNull);
    expect(ttmlCalls, 0);
  });

  test('auto: 择优选中 TTML 时来源标注带理由', () async {
    final r = await resolveLyricSource(
      BigInt.two,
      LyricSourceLoaders(
        yrc: (_) async => _scrambled(4),
        ttml: (_) async => _good(4),
        lineLevel: (_) async => throw StateError('分数悬殊不应调行级'),
      ),
    );
    expect(r?.source, 'ttml');
    expect(r?.reason, 'yrc 时间错乱');
    expect(lyricSourceLabel(r?.source, r?.reason), '逐字歌词 · AMLL(择优: yrc 时间错乱)');
  });

  test('auto: 分数接近时用行级 LRC 一致性加分决定(ttml 行首更贴近 LRC)', () async {
    // 两边都轻微不完美(首字偏移 100ms => firstWord 0, 得分 0.85 < 0.9),
    // 行级 LRC 更贴近 TTML 行首 => 一致性加分后 TTML 胜出. 这个用例同时锁住
    // "得分差 < 0.15 才额外取行级 LRC"这个窗口(Rust SCORE_CLOSE_WINDOW).
    var lineCalls = 0;
    final yrc = _good(2, firstWordShiftMs: 100); // 行首 0, 1000
    final ttml = _good(2, offsetMs: 500, firstWordShiftMs: 100); // 行首 500, 1500
    final r = await resolveLyricSource(
      BigInt.from(3),
      LyricSourceLoaders(
        yrc: (_) async => yrc,
        ttml: (_) async => ttml,
        lineLevel: (_) async {
          lineCalls++;
          return [
            rust.LyricLineDto(timeMs: BigInt.from(500), text: 'a', sub: null),
            rust.LyricLineDto(timeMs: BigInt.from(1500), text: 'b', sub: null),
          ];
        },
      ),
    );
    expect(lineCalls, 1);
    expect(r?.source, 'ttml');
    expect(lyricSourceLabel(r?.source, r?.reason), '逐字歌词 · AMLL(择优: yrc 首字偏移)');
  });

  test('auto: 分数悬殊时不额外取行级 LRC', () async {
    final r = await resolveLyricSource(
      BigInt.from(4),
      LyricSourceLoaders(
        yrc: (_) async => _scrambled(4),
        ttml: (_) async => _good(4),
        lineLevel: (_) async => throw StateError('分数悬殊不应调行级'),
      ),
    );
    expect(r?.source, 'ttml');
  });

  test('netease 偏好: yrc 覆盖率达标记为够好, 直接用(不调 TTML)', () async {
    var ttmlCalls = 0;
    final r = await resolveLyricSource(
      BigInt.from(5),
      LyricSourceLoaders(
        yrc: (_) async => _good(2),
        ttml: (_) async {
          ttmlCalls++;
          return _good(3);
        },
        lineLevel: (_) async => throw StateError('不应调行级'),
      ),
      preference: 'netease',
    );
    expect(r?.source, 'yrc');
    expect(ttmlCalls, 0);
  });
}
