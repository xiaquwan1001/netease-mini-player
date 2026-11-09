// B13: 逐字歌词三来源解析(yrc -> AMLL TTML -> 行级)的假 loader 单测.
// 全程不联网: loader 都是内存假实现.
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.WordLyricDto _wordLyric({
  required int lines,
  required bool wordTiming,
  List<bool>? perLineTimed,
}) => rust.WordLyricDto(
      lines: [
        for (var i = 0; i < lines; i++)
          rust.WordLyricLineDto(
            startMs: i * 1000,
            endMs: i * 1000 + 900,
            words: [
              if (wordTiming || (perLineTimed?[i] ?? false))
                rust.WordItemDto(startMs: i * 1000, endMs: i * 1000 + 900, text: 'w$i')
              else
                rust.WordItemDto(startMs: 0, endMs: 0, text: '整行词 $i'),
            ],
          ),
      ],
      translationLines: const [],
      hasWordTiming: wordTiming || (perLineTimed?.any((t) => t) ?? false),
    );

void main() {
  test('有合格 yrc 时不调 TTML(也不调行级)', () async {
    var ttmlCalls = 0, lineCalls = 0;
    final r = await resolveLyricSource(
      BigInt.from(1),
      LyricSourceLoaders(
        yrc: (_) async => _wordLyric(lines: 2, wordTiming: true),
        ttml: (_) async {
          ttmlCalls++;
          throw StateError('不应调用 TTML');
        },
        lineLevel: (_) async {
          lineCalls++;
          throw StateError('不应调用行级');
        },
      ),
    );
    expect(r?.source, 'yrc');
    expect(r?.word?.lines.length, 2);
    expect(ttmlCalls, 0);
    expect(lineCalls, 0);
  });

  test('yrc 覆盖率低于阈值(0.6)时改用 TTML', () async {
    // 2 行只有 1 行有词级时间 => 0.5 < 0.6
    final r = await resolveLyricSource(
      BigInt.from(2),
      LyricSourceLoaders(
        yrc: (_) async => _wordLyric(lines: 2, wordTiming: false, perLineTimed: [true, false]),
        ttml: (_) async => _wordLyric(lines: 3, wordTiming: true),
        lineLevel: (_) async => throw StateError('不应到行级'),
      ),
    );
    expect(r?.source, 'ttml');
    expect(r?.word?.lines.length, 3);
  });

  test('yrc 缺失(抛错)且 TTML 无数据时回退行级', () async {
    final r = await resolveLyricSource(
      BigInt.from(3),
      LyricSourceLoaders(
        yrc: (_) async => throw StateError('yrc 不支持'),
        ttml: (_) async => null, // 404 / .none 缓存
        lineLevel: (_) async => [
          rust.LyricLineDto(timeMs: BigInt.zero, text: '第一行', sub: null),
        ],
      ),
    );
    expect(r?.source, 'line');
    expect(r?.line?.single.text, '第一行');
  });

  test('TTML 解析/抓取失败回退不崩, 最终走行级', () async {
    final r = await resolveLyricSource(
      BigInt.from(4),
      LyricSourceLoaders(
        yrc: (_) async => null,
        ttml: (_) async => throw StateError('模拟 TTML 抓取失败'),
        lineLevel: (_) async => [
          rust.LyricLineDto(timeMs: BigInt.from(1000), text: '行级', sub: 'sub'),
        ],
      ),
    );
    expect(r?.source, 'line');
    expect(r?.line?.single.sub, 'sub');
  });

  test('yrc 差但非空且 TTML 也没有时, 保留差 yrc 而不是行级', () async {
    final r = await resolveLyricSource(
      BigInt.from(5),
      LyricSourceLoaders(
        yrc: (_) async => _wordLyric(lines: 1, wordTiming: false),
        ttml: (_) async => null,
        lineLevel: (_) async => throw StateError('有差 yrc 就不该到行级'),
      ),
    );
    expect(r?.source, 'yrc');
    expect(r?.word?.lines.single.words.single.text, '整行词 0');
  });

  test('全部来源失败返回 null(调用方走纯文本兜底)', () async {
    final r = await resolveLyricSource(
      BigInt.from(6),
      LyricSourceLoaders(
        yrc: (_) async => throw StateError('x'),
        ttml: (_) async => null,
        lineLevel: (_) async => const [],
      ),
    );
    expect(r, isNull);
  });

  test('yrcWordGoodEnough 阈值口径', () {
    expect(yrcWordGoodEnough(null), false);
    expect(yrcWordGoodEnough(_wordLyric(lines: 3, wordTiming: true)), true);
    // 3 行只有 2 行逐字 => 0.667 >= 0.6
    expect(
      yrcWordGoodEnough(
        _wordLyric(lines: 3, wordTiming: false, perLineTimed: [true, true, false]),
      ),
      true,
    );
    // 3 行只有 1 行逐字 => 0.333 < 0.6
    expect(
      yrcWordGoodEnough(
        _wordLyric(lines: 3, wordTiming: false, perLineTimed: [true, false, false]),
      ),
      false,
    );
  });
}
