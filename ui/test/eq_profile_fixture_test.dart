import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/eq_biquad.dart';
import 'package:minincm/src/eq_profile.dart';

/// 三端共享夹具(P-05 中期 / P-11)的 **Dart 侧** 断言.
///
/// 同一份 `ui/test/fixtures/eq_profile_cases.json` 也被
/// - Rust: `core/crates/ncm-domain/src/eq_profile.rs`(解析, `include_str!`)
/// - Rust: `core/crates/ncm-playback/src/biquad.rs`(系数, `include_str!`)
/// - Kotlin: `ui/android/app/src/test/.../EqProfileParserFixtureTest.kt`
/// 读取, 三端对同一 input 必须给出同一结果(含 biquad 首尾系数).
///
/// 断言口径: expect 里出现的字段才断言; `expectDart` 会浅覆盖 `expect`
/// (已知口径分叉单列, 见夹具 description).
void main() {
  final fixtureFile = File('test/fixtures/eq_profile_cases.json');
  final fixture =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();
  final floatTol = (fixture['floatTolerance'] as num).toDouble();
  final coefTol = (fixture['coefficientTolerance'] as num).toDouble();
  final sampleRate = (fixture['sampleRateHz'] as num).toDouble();

  Map<String, dynamic> expectedOf(Map<String, dynamic> c) {
    final base = c['expect'] as Map<String, dynamic>;
    final override = c['expectDart'] as Map<String, dynamic>?;
    return override == null ? base : {...base, ...override};
  }

  void expectMatch(String name, EqFilter actual, Map<String, dynamic> e) {
    expect(actual.type.name.toUpperCase(), e['kind'], reason: '$name: 类型');
    expect(actual.enabled, e['enabled'], reason: '$name: enabled');
    expect(
      actual.freqHz,
      closeTo((e['freqHz'] as num).toDouble(), floatTol),
      reason: '$name: fc',
    );
    expect(
      actual.gainDb,
      closeTo((e['gainDb'] as num).toDouble(), floatTol),
      reason: '$name: gain',
    );
    expect(
      actual.q,
      closeTo((e['q'] as num).toDouble(), floatTol),
      reason: '$name: q',
    );

    final biquad = e['biquad'] as List?;
    if (biquad != null) {
      final coeffs = EqBiquad.fromFilter(
        actual,
        sampleRate: sampleRate,
      ).coefficients;
      expect(coeffs.length, biquad.length);
      for (var i = 0; i < biquad.length; i++) {
        expect(
          coeffs[i],
          closeTo((biquad[i] as num).toDouble(), coefTol),
          reason: '$name: biquad[$i]',
        );
      }
    }
  }

  group('共享夹具 eq_profile_cases.json (Dart)', () {
    test('夹具自带用例数下限(防夹具被误删)', () {
      expect(cases.length, greaterThanOrEqualTo(20));
    });
    for (final c in cases) {
      final name = c['name'] as String;
      test(name, () {
        final exp = expectedOf(c);
        final input = c['input'] as String;

        ParametricEq? eq;
        EqProfileException? error;
        try {
          eq = parseParametricEq(input);
        } on EqProfileException catch (e) {
          error = e;
        }

        expect(
          eq != null,
          exp['ok'],
          reason: '$name: 期望 ${exp['ok'] ? '解析成功' : '解析失败'}, 实际 ${error ?? eq}',
        );
        if (exp['ok'] != true) {
          expect(error, isNotNull, reason: '$name: 应当抛 EqProfileException');
          expect(error!.line, exp['errorLine'], reason: '$name: 报错行号');
          return;
        }
        final parsed = eq!;
        if (exp.containsKey('errorLine')) {
          expect(exp['errorLine'], 0, reason: '$name: 成功用例的 errorLine 必须是 0');
        }
        if (exp.containsKey('preampDb')) {
          expect(
            parsed.preampDb,
            closeTo((exp['preampDb'] as num).toDouble(), floatTol),
            reason: '$name: preampDb',
          );
        }
        if (exp.containsKey('filterCount')) {
          expect(
            parsed.filters.length,
            exp['filterCount'],
            reason: '$name: filter 数',
          );
        }
        if (exp.containsKey('applied')) {
          expect(
            parsed.hasEffect,
            exp['applied'],
            reason: '$name: applied/hasEffect',
          );
        }
        for (final which in <String>['first', 'last']) {
          if (!exp.containsKey(which)) continue;
          final e = exp[which] as Map<String, dynamic>?;
          if (e == null) {
            expect(parsed.filters, isEmpty, reason: '$name: 期望没有 filter');
            continue;
          }
          expect(parsed.filters, isNotEmpty, reason: '$name: 期望有 filter');
          final actual = which == 'first'
              ? parsed.filters.first
              : parsed.filters.last;
          expectMatch('$name/$which', actual, e);
        }
      });
    }
  });
}
