// 歌词编排单测用的 RustLibApi 替身: 只实现打分/择优那 5 个纯函数.
//
// 打分权重/阈值/择优理由的唯一事实源在 Rust(core/crates/ncm-service/src/
// ttml_source.rs, 架构审计 7.3)。所以替身**不重算分数**: 用例直接脚本化
// "Rust 说了什么"(autoSkip / scoresClose / choice / goodEnough), 断言重点放在
// Dart 这半边 —— 探测顺序、省掉的那次 TTML / 行级请求、偏好分支。
// 数值与理由文案由 lyric_source_rust_parity_test.dart(本机有 cdylib 时跑真实
// Rust)与 `cargo test -p ncm-service ttml_source` 锁。
import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Int64List;

import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';

class FakeLyricPolicy implements RustLibApi {
  /// auto 模式: yrc 是否"好到不必探测 TTML"(Rust 侧 0.9 口径的结论)。
  bool autoSkip = false;

  /// 两来源得分是否接近(只有接近才会再取行级 LRC 做一致性加分)。
  bool scoresClose = false;

  /// netease 偏好: yrc 是否够好(Rust 侧覆盖率阈值口径的结论)。
  bool goodEnough = false;

  /// 择优结论: source 为 'yrc'/'ttml'/null, reason 为 Rust 给的短理由。
  String? choiceSource;
  String? choiceReason;

  int autoSkipCalls = 0;
  int closeCalls = 0;
  int chooseCalls = 0;
  int goodEnoughCalls = 0;

  /// 最近一次择优收到的行级起始时间(断言"接近时才取行级, 且取值口径对")。
  List<int> lastLineStarts = const [];

  /// 每个用例开头复位(initMock 一进程只能调一次, 所以替身复用 + 复位)。
  void reset() {
    autoSkip = false;
    scoresClose = false;
    goodEnough = false;
    choiceSource = null;
    choiceReason = null;
    autoSkipCalls = 0;
    closeCalls = 0;
    chooseCalls = 0;
    goodEnoughCalls = 0;
    lastLineStarts = const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  bool crateApiLyricAutoSkipTtml({required rust.WordLyricDto dto}) {
    autoSkipCalls++;
    return autoSkip;
  }

  @override
  bool crateApiLyricScoresClose({
    required rust.WordLyricDto yrc,
    required rust.WordLyricDto ttml,
  }) {
    closeCalls++;
    return scoresClose;
  }

  @override
  rust.LyricChoiceDto crateApiLyricChooseSource({
    rust.WordLyricDto? yrc,
    rust.WordLyricDto? ttml,
    required Int64List lineStarts,
  }) {
    chooseCalls++;
    // frb 的 Int64List 元素是 BigInt(而不是 dart:typed_data 的 Int64List)
    lastLineStarts = [for (final ms in lineStarts) ms.toInt()];
    return rust.LyricChoiceDto(source: choiceSource, reason: choiceReason);
  }

  @override
  bool crateApiLyricYrcGoodEnough({required rust.WordLyricDto dto}) {
    goodEnoughCalls++;
    return goodEnough;
  }
}
