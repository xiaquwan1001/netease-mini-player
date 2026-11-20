// C2: 逐字歌词来源偏好(auto/netease/amll)的**编排**单测 + 标注文案 + 设置项.
//
// 全程不联网: loader 都是内存假实现, 打分/择优结论由 [FakeLyricPolicy] 脚本化。
// 打分权重/阈值/理由文案本身只在 Rust 一份(架构审计 7.3), 它们的数值断言在
// lyric_source_rust_parity_test.dart(真实 Rust)/ cargo test -p ncm-service.
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';

import 'support/lyric_policy_fake.dart';

rust.WordLyricDto _good(int lines) => rust.WordLyricDto(
  lines: [
    for (var i = 0; i < lines; i++)
      rust.WordLyricLineDto(
        startMs: i * 1000,
        endMs: i * 1000 + 900,
        words: [
          rust.WordItemDto(startMs: i * 1000, endMs: i * 1000 + 400, text: '你'),
          rust.WordItemDto(
            startMs: i * 1000 + 400,
            endMs: i * 1000 + 900,
            text: '好',
          ),
        ],
      ),
  ],
  translationLines: const [],
  hasWordTiming: true,
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

  test('auto: 策略说 yrc 得分已很高时跳过 TTML 探测(不联网)', () async {
    policy.autoSkip = true;
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
    expect(policy.autoSkipCalls, 1);
    expect(ttmlCalls, 0);
  });

  test('auto: 择优选 TTML 时来源标注带 Rust 给的理由', () async {
    policy.choiceSource = 'ttml';
    policy.choiceReason = 'yrc 时间错乱';
    final r = await resolveLyricSource(
      BigInt.two,
      LyricSourceLoaders(
        yrc: (_) async => _good(4),
        ttml: (_) async => _good(4),
        lineLevel: (_) async => throw StateError('分数悬殊不应调行级'),
      ),
    );
    expect(r?.source, 'ttml');
    expect(r?.reason, 'yrc 时间错乱');
    expect(lyricSourceLabel(r?.source, r?.reason), '逐字歌词 · AMLL(择优: yrc 时间错乱)');
  });

  test('auto: 分数接近才取行级 LRC 起始时间喂给择优(不接近就省一次请求)', () async {
    policy.choiceSource = 'ttml';
    policy.choiceReason = 'yrc 首字偏移';
    policy.scoresClose = true;
    final r = await resolveLyricSource(
      BigInt.from(3),
      LyricSourceLoaders(
        yrc: (_) async => _good(2),
        ttml: (_) async => _good(2),
        lineLevel: (_) async => [
          rust.LyricLineDto(timeMs: BigInt.from(500), text: 'a', sub: null),
          rust.LyricLineDto(timeMs: BigInt.from(1500), text: 'b', sub: null),
        ],
      ),
    );
    expect(policy.closeCalls, 1);
    // 行级 loader 的 timeMs 原样转成毫秒整数喂给 Rust
    expect(policy.lastLineStarts, equals(<int>[500, 1500]));
    expect(r?.source, 'ttml');
    expect(lyricSourceLabel(r?.source, r?.reason), '逐字歌词 · AMLL(择优: yrc 首字偏移)');
  });

  test('auto: 择优选 yrc 时也把理由(如"yrc 质量更优")带回去', () async {
    policy.choiceSource = 'yrc';
    policy.choiceReason = 'yrc 质量更优';
    final r = await resolveLyricSource(
      BigInt.from(4),
      LyricSourceLoaders(
        yrc: (_) async => _good(2),
        ttml: (_) async => _good(2),
        lineLevel: (_) async => null,
      ),
    );
    expect(r?.source, 'yrc');
    expect(r?.reason, 'yrc 质量更优');
    expect(lyricSourceLabel(r?.source, r?.reason), '逐字歌词 · 网易云(择优: yrc 质量更优)');
  });

  test('netease 偏好: 策略判 yrc 够好就直接用(不调 TTML, 不择优)', () async {
    policy.goodEnough = true;
    var ttmlCalls = 0;
    final r = await resolveLyricSource(
      BigInt.from(5),
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
    expect(policy.goodEnoughCalls, 1);
    expect(policy.autoSkipCalls, 0); // netease 不走 auto 的跳过规则
    expect(policy.chooseCalls, 0);
    expect(ttmlCalls, 0);
  });

  test('netease 偏好: yrc 不够好时改投 TTML', () async {
    policy.goodEnough = false;
    final r = await resolveLyricSource(
      BigInt.from(6),
      LyricSourceLoaders(
        yrc: (_) async => null,
        ttml: (_) async => _good(3),
        lineLevel: (_) async => throw StateError('有 TTML 不该到行级'),
      ),
      preference: 'netease',
    );
    expect(r?.source, 'ttml');
    expect(r?.reason, isNull);
  });

  test('amll 偏好: 即使 yrc 很好也优先 TTML, TTML 失败再 yrc, 且不问策略', () async {
    final r1 = await resolveLyricSource(
      BigInt.from(7),
      LyricSourceLoaders(
        yrc: (_) async => _good(3),
        ttml: (_) async => _good(3),
        lineLevel: (_) async => null,
      ),
      preference: 'amll',
    );
    expect(r1?.source, 'ttml');
    final r2 = await resolveLyricSource(
      BigInt.from(8),
      LyricSourceLoaders(
        yrc: (_) async => _good(3),
        ttml: (_) async => null,
        lineLevel: (_) async => null,
      ),
      preference: 'amll',
    );
    expect(r2?.source, 'yrc');
    expect(r2?.reason, isNull);
    // amll 是单路优先, 既不打分也不择优
    expect(policy.autoSkipCalls, 0);
    expect(policy.closeCalls, 0);
    expect(policy.chooseCalls, 0);
    expect(policy.goodEnoughCalls, 0);
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
    expect(
      AppSettings.instance.lyricSourcePreference,
      'amll',
    ); // 默认值(2026-11-15 起)
    expect(AppSettings.lyricSourceOptions.keys.toSet(), {
      'auto',
      'netease',
      'amll',
    });
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
      '默认: 优先 AMLL TTML 逐字(人工审核库), 缺失再用网易云 yrc',
    );
    final s = AppSettings.instance;
    s.update(lyricSourcePreference: 'auto');
    expect(s.lyricSourcePreference, 'auto');
    s.update(lyricSourcePreference: 'bogus');
    expect(s.lyricSourcePreference, 'auto'); // 非法值被拒
    s.update(lyricSourcePreference: 'amll');
  });
}
