// C2: 逐字歌词来源偏好(auto/netease/amll) + 打分择优 + 标注文案的单测.
// 全程不联网: loader 都是内存假实现.
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.WordLyricDto _good(int lines, {int offsetMs = 0, int firstWordShiftMs = 0}) =>
    rust.WordLyricDto(
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

rust.WordLyricDto _scrambled(int lines) {
  final starts = [9000, 2000, 7000, 4000];
  return rust.WordLyricDto(
    lines: [
      for (var i = 0; i < lines; i++)
        rust.WordLyricLineDto(
          startMs: starts[i],
          endMs: starts[i] + 900,
          words: [
            rust.WordItemDto(startMs: starts[i], endMs: starts[i] + 400, text: '你'),
          ],
        ),
    ],
    translationLines: const [],
    hasWordTiming: true,
  );
}

void main() {
  test('scoreWordLyric: 完好 yrc 满分, 退化(无词级时间)低分', () {
    final s = scoreWordLyric(_good(3));
    expect(s.score, closeTo(1.0, 1e-9));
    final d = rust.WordLyricDto(
      lines: [
        rust.WordLyricLineDto(
          startMs: 0,
          endMs: 0,
          words: [rust.WordItemDto(startMs: 0, endMs: 0, text: '整行')],
        ),
      ],
      translationLines: const [],
      hasWordTiming: false,
    );
    final sd = scoreWordLyric(d);
    expect(sd.coverage, 0.0);
    expect(sd.spans, 0.0);
    expect(sd.score, lessThan(0.6));
  });

  test('auto 择优: yrc 覆盖率高但时间错乱应输给 TTML(理由: yrc 时间错乱)', () {
    final c = chooseWordSource(_scrambled(4), _good(4));
    expect(c.source, 'ttml');
    expect(c.reason, 'yrc 时间错乱');
  });

  test('auto: yrc 得分已很高(>=0.9)时跳过 TTML 探测(不联网)', () async {
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
    // 行级 LRC 更贴近 TTML 行首 => 一致性加分后 TTML 胜出.
    final yrc = _good(2, firstWordShiftMs: 100); // 行首 0, 1000
    final ttml = _good(2, offsetMs: 500, firstWordShiftMs: 100); // 行首 500, 1500
    final r = await resolveLyricSource(
      BigInt.from(3),
      LyricSourceLoaders(
        yrc: (_) async => yrc,
        ttml: (_) async => ttml,
        lineLevel: (_) async => [
          rust.LyricLineDto(timeMs: BigInt.from(500), text: 'a', sub: null),
          rust.LyricLineDto(timeMs: BigInt.from(1500), text: 'b', sub: null),
        ],
      ),
    );
    expect(r?.source, 'ttml');
    expect(lyricSourceLabel(r?.source, r?.reason), '逐字歌词 · AMLL(择优: yrc 首字偏移)');
  });

  test('netease 偏好: yrc 够好直接用(不调 TTML)', () async {
    var ttmlCalls = 0;
    final r = await resolveLyricSource(
      BigInt.from(4),
      LyricSourceLoaders(
        yrc: (_) async => _good(2),
        ttml: (_) async {
          ttmlCalls++;
          return _good(2);
        },
        lineLevel: (_) async => throw StateError('不应调行级'),
      ),
      preference: 'netease',
    );
    expect(r?.source, 'yrc');
    expect(ttmlCalls, 0);
  });

  test('amll 偏好: 即使 yrc 很好也优先 TTML, TTML 失败再 yrc', () async {
    final r1 = await resolveLyricSource(
      BigInt.from(5),
      LyricSourceLoaders(
        yrc: (_) async => _good(3),
        ttml: (_) async => _good(3),
        lineLevel: (_) async => null,
      ),
      preference: 'amll',
    );
    expect(r1?.source, 'ttml');
    final r2 = await resolveLyricSource(
      BigInt.from(6),
      LyricSourceLoaders(
        yrc: (_) async => _good(3),
        ttml: (_) async => null,
        lineLevel: (_) async => null,
      ),
      preference: 'amll',
    );
    expect(r2?.source, 'yrc');
    expect(r2?.reason, isNull);
  });

  test('lyricSourceLabel: 三来源 + 无理由 + 行级不带择优后缀', () {
    expect(lyricSourceLabel('yrc', null), '逐字歌词 · 网易云');
    expect(lyricSourceLabel('ttml', null), '逐字歌词 · AMLL');
    expect(lyricSourceLabel('line', null), '逐行歌词');
    expect(lyricSourceLabel('line', 'yrc 覆盖低'), '逐行歌词');
    expect(lyricSourceLabel('yrc', 'yrc 质量更优'), '逐字歌词 · 网易云(择优: yrc 质量更优)');
    expect(lyricSourceLabel(null, null), '');
  });

  test('AppSettings: 歌词来源偏好三态 + 副标题语义', () {
    expect(AppSettings.instance.lyricSourcePreference, 'auto'); // 默认值
    expect(AppSettings.lyricSourceOptions.keys.toSet(), {'auto', 'netease', 'amll'});
    expect(
      AppSettings.lyricSourceDescription('auto'),
      '给 yrc 与 AMLL 打分择优, yrc 质量高时不联网比较',
    );
    expect(
      AppSettings.lyricSourceDescription('netease'),
      '只用网易云 yrc, 缺失才用 AMLL TTML',
    );
    expect(
      AppSettings.lyricSourceDescription('amll'),
      '优先 AMLL TTML, 失败再用网易云 yrc',
    );
    final s = AppSettings.instance;
    s.update(lyricSourcePreference: 'amll');
    expect(s.lyricSourcePreference, 'amll');
    s.update(lyricSourcePreference: 'bogus');
    expect(s.lyricSourcePreference, 'amll'); // 非法值被拒
    s.update(lyricSourcePreference: 'auto');
  });
}
