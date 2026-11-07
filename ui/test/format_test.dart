import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/format.dart';

void main() {
  group('formatDurationMs: h:mm:ss / mm:ss 统一口径', () {
    test('不足一小时用 mm:ss', () {
      expect(formatDurationMs(BigInt.from(245000)), '04:05');
      expect(formatDurationMs(BigInt.zero), '00:00');
      // 负值不在展示范围, 与原 4 份实现同口径(向零取整)
      expect(formatDurationMs(BigInt.from(-5000)), '59:55');
      expect(formatDurationMs(BigInt.from(3599000)), '59:59');
    });

    test('满一小时用 h:mm:ss, 小时不补零', () {
      expect(formatDurationMs(BigInt.from(3600000)), '1:00:00');
      expect(formatDurationMs(BigInt.from(3661000)), '1:01:01');
      expect(formatDurationMs(BigInt.from(36000000)), '10:00:00');
    });
  });
}
