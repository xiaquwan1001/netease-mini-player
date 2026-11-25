// 共享格式化口径的收敛用例(2026-11-25 审计 D01/D02)。
//
// 这两个函数原来是多份副本, 合并后必须保证**输出逐字不变**:
//   · D01 `relativeTime`: 原 `messages/message_shared.dart` /
//     `feed_detail_page.feedRelativeTime` / `comment_thread._relative` 三份;
//   · D02 `formatDurationClock`: 原 `player_bar._fmt` / `stream_note._fmtMs` 两份
//     (与 `formatDurationMs` 的 `h:mm:ss` 口径刻意不同)。
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/feed_detail_page.dart' show feedRelativeTime;
import 'package:minincm/src/format.dart';
import 'package:minincm/src/messages/message_shared.dart'
    as messages
    show relativeTime;

BigInt _msAgo(Duration d) =>
    BigInt.from(DateTime.now().subtract(d).millisecondsSinceEpoch);

void main() {
  group('formatDurationClock: mm:ss 累计(播放条/试听提示口径)', () {
    test('不足一小时补零到 mm:ss', () {
      expect(formatDurationClock(BigInt.zero), '00:00');
      expect(formatDurationClock(BigInt.from(245000)), '04:05');
      expect(formatDurationClock(BigInt.from(9000)), '00:09');
      expect(formatDurationClock(BigInt.from(3599000)), '59:59');
    });

    test('满一小时也不换 h:mm:ss(与 formatDurationMs 的刻意差异)', () {
      expect(formatDurationClock(BigInt.from(3600000)), '60:00');
      expect(formatDurationClock(BigInt.from(3961000)), '66:01');
      // 同一输入两种口径: 钟表串累计, 通用时长换小时位
      expect(formatDurationMs(BigInt.from(3961000)), '1:06:01');
    });

    test('负值向零取整(与原 _fmt/_fmtMs 同口径, 不回绕成 59:55)', () {
      expect(formatDurationClock(BigInt.from(-5000)), '00:55');
      expect(formatDurationMs(BigInt.from(-5000)), '59:55');
    });
  });

  group('relativeTime: 阈值 1/60/24/30 + yyyy-MM-dd 兜底', () {
    test('≤0(接口没给)返回空串', () {
      expect(relativeTime(BigInt.zero), '');
      expect(relativeTime(BigInt.from(-1000)), '');
    });

    test('刚刚 / 分钟 / 小时 / 天', () {
      expect(relativeTime(_msAgo(const Duration(seconds: 5))), '刚刚');
      expect(relativeTime(_msAgo(const Duration(minutes: 5))), '5 分钟前');
      expect(relativeTime(_msAgo(const Duration(hours: 5))), '5 小时前');
      expect(relativeTime(_msAgo(const Duration(days: 5))), '5 天前');
      expect(relativeTime(_msAgo(const Duration(days: 29))), '29 天前');
    });

    test('满 30 天退回 yyyy-MM-dd', () {
      final old = _msAgo(const Duration(days: 30, hours: 2));
      expect(relativeTime(old), formatDateYmd(old));
      expect(relativeTime(old), matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
    });

    test('三处入口输出逐字一致(合并后仍只有一份实现)', () {
      for (final t in <BigInt>[
        BigInt.zero,
        _msAgo(const Duration(seconds: 5)),
        _msAgo(const Duration(minutes: 5)),
        _msAgo(const Duration(hours: 5)),
        _msAgo(const Duration(days: 5)),
        _msAgo(const Duration(days: 40)),
      ]) {
        expect(feedRelativeTime(t), relativeTime(t));
        expect(messages.relativeTime(t), relativeTime(t));
      }
    });
  });
}
