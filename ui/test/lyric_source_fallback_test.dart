// B13: 逐字歌词三来源解析(yrc -> AMLL TTML -> 行级)的**编排**单测.
//
// 全程不联网: 三个 loader 都是内存假实现。打分/择优的结论由 [FakeLyricPolicy]
// 脚本化 —— 规则数值的唯一事实源在 Rust(架构审计 7.3), Dart 侧现在只剩
// "先探谁 / 省掉哪次请求"这层编排, 这里断言的就是它。
// 数值与理由文案见 lyric_source_rust_parity_test.dart(真实 Rust)与
// `cargo test -p ncm-service ttml_source`。
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';

import 'support/lyric_policy_fake.dart';

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
            rust.WordItemDto(
              startMs: i * 1000,
              endMs: i * 1000 + 900,
              text: 'w$i',
            )
          else
            rust.WordItemDto(startMs: 0, endMs: 0, text: '整行词 $i'),
        ],
      ),
  ],
  translationLines: const [],
  hasWordTiming: wordTiming || (perLineTimed?.any((t) => t) ?? false),
);

void main() {
  late FakeLyricPolicy policy;

  setUpAll(() {
    policy = FakeLyricPolicy();
    RustLib.initMock(api: policy);
  });
  // 必须**调用** reset: `setUp(() => policy.reset)` 只返回 tear-off, 计数器会跨用例累加.
  setUp(() {
    policy.reset();
  });

  test('yrc 够好(策略说不必探测)时不调 TTML, 也不调行级', () async {
    policy.autoSkip = true;
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
    expect(r?.reason, isNull);
    expect(policy.autoSkipCalls, 1); // 只问了一次策略
    expect(ttmlCalls, 0);
    expect(lineCalls, 0);
    expect(policy.chooseCalls, 0); // 早退, 没有择优
  });

  test('策略判 yrc 不合格且择优选 TTML 时改用 TTML(不额外取行级)', () async {
    policy.choiceSource = 'ttml';
    policy.choiceReason = 'yrc 覆盖低';
    final r = await resolveLyricSource(
      BigInt.from(2),
      LyricSourceLoaders(
        yrc: (_) async => _wordLyric(
          lines: 2,
          wordTiming: false,
          perLineTimed: [true, false],
        ),
        ttml: (_) async => _wordLyric(lines: 3, wordTiming: true),
        lineLevel: (_) async => throw StateError('不应到行级'),
      ),
    );
    expect(policy.autoSkipCalls, 1);
    expect(policy.chooseCalls, 1);
    // 策略说"得分不接近" => 不该为一致性多取一次行级 LRC
    expect(policy.closeCalls, 1);
    expect(policy.lastLineStarts, isEmpty);
    expect(r?.source, 'ttml');
    expect(r?.reason, 'yrc 覆盖低');
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
    expect(policy.autoSkipCalls, 0); // 没有 yrc, 不必问策略
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
    policy.choiceSource = 'yrc';
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

  test('yrcWordGoodEnough 只把结论转发给 Rust(null 直接 false, 不调 FFI)', () {
    expect(yrcWordGoodEnough(null), false);
    expect(policy.goodEnoughCalls, 0);
    policy.goodEnough = true;
    expect(yrcWordGoodEnough(_wordLyric(lines: 3, wordTiming: true)), true);
    expect(policy.goodEnoughCalls, 1);
    policy.goodEnough = false;
    expect(yrcWordGoodEnough(_wordLyric(lines: 3, wordTiming: true)), false);
  });
}
