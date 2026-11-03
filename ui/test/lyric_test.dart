import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/lyric.dart';

BigInt _ms(int v) => BigInt.from(v);

void main() {
  group('lyricIndexAt', () {
    final times = [_ms(1000), _ms(5000), _ms(9000), _ms(20000)];

    test('第一句之前返回 -1', () {
      expect(lyricIndexAt(times, _ms(0)), -1);
      expect(lyricIndexAt(times, _ms(999)), -1);
    });

    test('正好等于时间戳时命中该行', () {
      expect(lyricIndexAt(times, _ms(1000)), 0);
      expect(lyricIndexAt(times, _ms(9000)), 2);
    });

    test('落在两行之间取前一行', () {
      expect(lyricIndexAt(times, _ms(4999)), 0);
      expect(lyricIndexAt(times, _ms(12000)), 2);
    });

    test('超过最后一句停在最后一行', () {
      expect(lyricIndexAt(times, _ms(999999)), 3);
    });

    test('空歌词返回 -1', () {
      expect(lyricIndexAt(const [], _ms(5000)), -1);
    });
  });
}
