import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/eq_profile.dart';

/// AutoEQ 曲线解析/序列化契约测试(docs/plan-2026-11-09-settings-and-player.md §2.2).
void main() {
  void expectEqError(String text, {int? line, String? containsText}) {
    try {
      parseParametricEq(text);
      fail('应当抛出 EqProfileException');
    } on EqProfileException catch (e) {
      if (line != null) expect(e.line, line);
      if (containsText != null) expect(e.reason, contains(containsText));
    }
  }

  group('parseParametricEq', () {
    test('合法样例: 字段解析正确且往返一致(幂等)', () {
      const text =
          'Preamp: -6.0 dB\n'
          'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\n'
          'Filter 2: ON LS Fc 120 Hz Gain 2.5 dB Q 0.70\n';
      final eq = parseParametricEq(text);

      expect(eq.preampDb, -6.0);
      expect(eq.filters.length, 2);
      expect(eq.filters[0].index, 1);
      expect(eq.filters[0].enabled, isTrue);
      expect(eq.filters[0].type, EqFilterType.pk);
      expect(eq.filters[0].freqHz, 105.0);
      expect(eq.filters[0].gainDb, -3.2);
      expect(eq.filters[0].q, closeTo(0.71, 1e-9));
      expect(eq.filters[1].type, EqFilterType.ls);
      expect(eq.filters[1].freqHz, 120.0);

      final out = eq.toParametricEqText();
      expect(out, contains('Preamp: -6.0 dB'));
      expect(out, contains('Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71'));

      // 幂等往返: 再解析一次, 字段完全一致.
      final eq2 = parseParametricEq(out);
      expect(eq2.preampDb, eq.preampDb);
      expect(eq2.filters.length, eq.filters.length);
      for (var i = 0; i < eq.filters.length; i++) {
        expect(eq2.filters[i].index, eq.filters[i].index);
        expect(eq2.filters[i].enabled, eq.filters[i].enabled);
        expect(eq2.filters[i].type, eq.filters[i].type);
        expect(eq2.filters[i].freqHz, eq.filters[i].freqHz);
        expect(eq2.filters[i].gainDb, eq.filters[i].gainDb);
        expect(eq2.filters[i].q, eq.filters[i].q);
      }
    });

    test('Preamp 可选: 缺省 0 dB; OFF 保留并可往返', () {
      final eq = parseParametricEq(
        'Filter 1: OFF HS Fc 1000 Hz Gain -1.0 dB Q 0.5\n',
      );
      expect(eq.preampDb, 0.0);
      expect(eq.filters.single.enabled, isFalse);
      expect(eq.toParametricEqText(), contains('Preamp: 0.0 dB'));
      expect(
        eq.toParametricEqText(),
        contains('Filter 1: OFF HS Fc 1000 Hz Gain -1.0 dB Q 0.5'),
      );
    });

    test('Q 缺失报错(行号正确)', () {
      expectEqError(
        'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB',
        line: 1,
        containsText: 'Q',
      );
    });

    test('Gain 超 ±24 dB 报错(不静默裁剪)', () {
      expectEqError(
        'Filter 1: ON PK Fc 105 Hz Gain 25.0 dB Q 0.71',
        line: 1,
        containsText: '24',
      );
    });

    test('第 21 个 filter 报错', () {
      final buf = StringBuffer('Preamp: 0.0 dB\n');
      for (var i = 1; i <= 21; i++) {
        final freq = 100 * i;
        buf.writeln('Filter $i: ON PK Fc $freq Hz Gain -1.0 dB Q 0.7');
      }
      expectEqError(buf.toString(), line: 22, containsText: '20');
    });

    test('未知类型(LP)明确报不支持', () {
      expectEqError(
        'Filter 1: ON LP Fc 105 Hz Gain -3.2 dB Q 0.71',
        line: 1,
        containsText: '不支持',
      );
    });

    test('非数字 Gain 报错(行号正确)', () {
      expectEqError(
        'Filter 1: ON PK Fc 105 Hz Gain -x.2 dB Q 0.71',
        line: 1,
        containsText: 'Gain',
      );
    });

    test('Q 非正数报错', () {
      expectEqError(
        'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0',
        line: 1,
        containsText: 'Q',
      );
    });

    test('空行不占位, 行号按原文计算', () {
      expectEqError(
        '\nFilter 1: ON PK Fc 105 Hz Gain -3.2 dB',
        line: 2,
        containsText: 'Q',
      );
    });

    test('注释行(# 与 //)忽略', () {
      final eq = parseParametricEq(
        '# AutoEQ\n// note\nFilter 1: ON PK Fc 100 Hz Gain 2.0 dB Q 1.0\n',
      );
      expect(eq.filters.length, 1);
      expect(eq.preampDb, 0.0);
      expect(eq.filters.single.freqHz, 100.0);
    });
  });
}
