import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/format.dart';
import 'package:minincm/src/song_tile.dart' show formatSongDuration;

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

  group('formatSongDuration: 歌曲行定长 mm:ss(负值钳 0)', () {
    test('非负区间与 formatDurationMs 输出一致', () {
      expect(formatSongDuration(BigInt.from(245000)), '04:05');
      expect(formatSongDuration(BigInt.zero), '00:00');
      expect(formatSongDuration(BigInt.from(3600000)), '1:00:00');
      expect(formatSongDuration(BigInt.from(3661000)), '1:01:01');
    });

    test('负值钳 0(与共享口径的唯一差异)', () {
      // formatDurationMs 回绕成 59:55, 歌曲行口径钳 0
      expect(formatSongDuration(BigInt.from(-5000)), '00:00');
    });
  });

  group('formatDurationShort: 新歌页 m:ss 不补零口径', () {
    test('分钟不补零, ≤0 返回空串', () {
      expect(formatDurationShort(BigInt.from(245000)), '4:05');
      expect(formatDurationShort(BigInt.from(60000)), '1:00');
      expect(formatDurationShort(BigInt.zero), '');
      expect(formatDurationShort(BigInt.from(-1)), '');
    });

    test('无小时位: 超 60 分钟继续累计', () {
      expect(formatDurationShort(BigInt.from(3961000)), '66:01');
    });
  });

  group('formatDateYmd: yyyy-MM-dd(本地时区, 月/日补零)', () {
    test('补零与跨月边界', () {
      expect(
        formatDateYmd(
          BigInt.from(DateTime(2026, 1, 5, 12).millisecondsSinceEpoch),
        ),
        '2026-01-05',
      );
      expect(
        formatDateYmd(
          BigInt.from(DateTime(2026, 2, 1, 12).millisecondsSinceEpoch),
        ),
        '2026-02-01',
      );
      expect(
        formatDateYmd(
          BigInt.from(DateTime(2026, 11, 23, 12).millisecondsSinceEpoch),
        ),
        '2026-11-23',
      );
    });
  });

  group('formatCountMagnitude', () {
    test('千以下给准确值, 千/万/亿给下界 + 加号', () {
      expect(formatCountMagnitude(0), '0');
      expect(formatCountMagnitude(1), '1');
      expect(formatCountMagnitude(999), '999');
      expect(formatCountMagnitude(1000), '1k+');
      expect(formatCountMagnitude(3999), '3k+');
      expect(formatCountMagnitude(9999), '9k+');
      expect(formatCountMagnitude(10000), '1w+');
      expect(formatCountMagnitude(12345), '1w+');
      expect(formatCountMagnitude(99999999), '9999w+');
      expect(formatCountMagnitude(100000000), '1亿+');
      // 负值(接口异常)按 0 处理, 不抛也不显示 "-1"
      expect(formatCountMagnitude(-5), '0');
    });
  });
}
