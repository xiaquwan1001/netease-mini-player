import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/eq_curve_chart.dart';
import 'package:minincm/src/eq_profile.dart';
import 'package:minincm/src/settings_audio_page.dart';

const sampleText = 'Preamp: -6.0 dB\n'
    'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\n'
    'Filter 2: ON LS Fc 120 Hz Gain 2.5 dB Q 0.70\n'
    'Filter 3: ON HS Fc 8000 Hz Gain 1.5 dB Q 0.70';

ParametricEq parseOk(String text) => parseParametricEq(text);

void main() {
  final settings = AppSettings.instance;
  String? savedName;
  String? savedText;

  setUp(() {
    savedName = settings.eqProfileName;
    savedText = settings.eqProfileText;
  });
  tearDown(() {
    settings.eqProfileName = savedName;
    settings.eqProfileText = savedText;
    settings.notifyListeners();
  });

  group('纯函数: 频率响应', () {
    test('PK 峰值位置在 Fc 附近且接近 Preamp+Gain', () {
      final eq = parseOk(sampleText);
      final dbs = evaluateEqDb(eq, [100.0, 105.0, 110.0]);
      // PK 105 Hz(-3.2) + LS(约+1.4) + Preamp -6 → 约 -7.8 dB.
      expect(dbs[1], closeTo(-7.8, 0.6));
      // PK 谷点应在 105 Hz 附近.
      final fine = evaluateEqDb(eq, [95, 100, 105, 110, 115]);
      expect(fine.reduce(math.min), closeTo(-7.8, 1.2));
    });

    test('远离 filter 的频点回落到 0 dB 附近(含 Preamp)', () {
      final eq = parseOk(sampleText);
      final mid = evaluateEqDb(eq, [1500.0]).first;
      expect(mid, closeTo(-6.0, 1.5));
      // HS 8k +1.5 → 15 kHz 应 > -6 (有提抬).
      final high = evaluateEqDb(eq, [15000.0]).first;
      expect(high, greaterThan(mid));
    });

    test('computeCurve: 单调 x、值域 clamp、点数正确', () {
      final eq = parseOk(sampleText);
      final pts = computeCurve(eq, const Size(300, 180));
      expect(pts.length, 160);
      for (var i = 1; i < pts.length; i++) {
        expect(pts[i].dx, greaterThanOrEqualTo(pts[i - 1].dx));
        expect(pts[i].dy, inInclusiveRange(0, 180));
      }
      // 0 dB 基准线在中间.
      expect(eqCurveY(0, 180), 90);
      // 对数频率映射: 1k 在 20~20k 的位置约为 (log(50)/log(1000)) 比例.
      final x1k = eqCurveX(1000, 300);
      expect(x1k / 300, closeTo(math.log(1000 / 20) / math.log(1000), 1e-6));
    });

    test('rewriteEqFilterGain: 只改目标 filter, 其余不变且幂等可再解析', () {
      final eq = parseOk(sampleText);
      final next = rewriteEqFilterGain(eq, 1, -8.0);
      final eq2 = parseOk(next);
      expect(eq2.filters.length, 3);
      expect(eq2.filters[0].gainDb, -8.0);
      expect(eq2.filters[0].type, EqFilterType.pk);
      expect(eq2.filters[1].gainDb, 2.5);
      expect(eq2.filters[1].freqHz, 120);
      expect(eq2.filters[2].gainDb, 1.5);
      expect(eq2.preampDb, -6.0);
      expect(next, rewriteEqFilterGain(eq2, 1, -8.0));
    });

    test('eqFreqLabel', () {
      expect(eqFreqLabel(20), '20');
      expect(eqFreqLabel(500), '500');
      expect(eqFreqLabel(1000), '1k');
      expect(eqFreqLabel(105), '105');
      expect(eqFreqLabel(20000), '20k');
    });
  });

  Future<void> pumpPanel(
    WidgetTester tester, {
    String? text,
    Size size = const Size(400, 232),
    TextScaler textScaler = TextScaler.noScaling,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: brightness,
          ),
        ),
        home: Scaffold(
          body: MediaQuery(
            data: MediaQueryData(textScaler: textScaler),
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: EqCurvePanel(
                text: text,
                onChanged: (t) => settings.update(
                  eqProfileText: t,
                  eqProfileName: '自定义曲线',
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空态: 未启用时显示导入提示, 不崩', (tester) async {
    await pumpPanel(tester, text: null);
    expect(find.textContaining('未启用自定义曲线'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认显示曲线视图, 可切到柱状视图', (tester) async {
    await pumpPanel(tester, text: sampleText);
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.tap(find.text('柱状'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('曲线'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('非法曲线: 显示带行号错误, 不崩', (tester) async {
    await pumpPanel(tester, text: 'Preamp: -6.0 dB\nFilter 1: ON LP Fc 100 Hz Gain 1 dB Q 0.7');
    expect(find.textContaining('第 2 行'), findsOneWidget);
    expect(find.textContaining('不支持'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('柱状图: 拖动改变 Gain 写回 eqProfileText, 其它 filter 不变', (tester) async {
    settings.eqProfileText = sampleText;
    settings.eqProfileName = '自定义曲线';
    settings.notifyListeners();
    await pumpPanel(tester, text: sampleText);
    await tester.tap(find.text('柱状'));
    await tester.pumpAndSettle();

    // 第 2 根柱(Fc 120, LS). 柱宽 = 面板宽/3; 向上拖 24px ≈ +5.9 dB.
    final size = tester.getSize(find.byType(EqCurvePanel));
    final colW = size.width / 3;
    final barCenter = Offset(colW * 1.5, 232 / 2);
    final gesture = await tester.startGesture(barCenter);
    await tester.pump();
    await gesture.moveBy(const Offset(0, -24));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final eq2 = parseOk(settings.eqProfileText!);
    final ls = eq2.filters.firstWhere((f) => f.type == EqFilterType.ls);
    expect(ls.gainDb, greaterThan(2.5));
    // 其它 filter 保持不变.
    final pk = eq2.filters.firstWhere((f) => f.type == EqFilterType.pk);
    final hs = eq2.filters.firstWhere((f) => f.type == EqFilterType.hs);
    expect(pk.gainDb, -3.2);
    expect(hs.gainDb, 1.5);
    expect(eq2.preampDb, -6.0);
    expect(settings.eqProfileName, '自定义曲线');
  });

  testWidgets('柱状图: 拖到 0 不删除 filter, 序列化仍在', (tester) async {
    settings.eqProfileText = 'Preamp: 0.0 dB\nFilter 1: ON PK Fc 100 Hz Gain 4.0 dB Q 0.7';
    settings.notifyListeners();
    await pumpPanel(tester, text: settings.eqProfileText);
    await tester.tap(find.text('柱状'));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(EqCurvePanel));
    // 柱顶端在 0dB 线上方, 从中部向下拖把柱压回 0 附近.
    final gesture = await tester.startGesture(Offset(size.width / 2, 232 / 2));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final eq = parseOk(settings.eqProfileText!);
    expect(eq.filters.length, 1);
    expect(eq.filters.first.gainDb, lessThan(4.0));
  });

  testWidgets('曲线触摸读数: 拖动不崩且画布保持', (tester) async {
    await pumpPanel(tester, text: sampleText);
    final size = tester.getSize(find.byType(EqCurvePanel));
    final gesture = await tester.startGesture(Offset(size.width / 2, size.height / 2));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('300dp + 1.25 字号: 不溢出', (tester) async {
    await pumpPanel(
      tester,
      text: sampleText,
      size: const Size(300, 232),
      textScaler: const TextScaler.linear(1.25),
    );
    await tester.tap(find.text('柱状'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(Column), findsWidgets);
  });

  testWidgets('深色主题: 曲线/柱状均不抛异常', (tester) async {
    await pumpPanel(tester, text: sampleText, brightness: Brightness.dark);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('柱状'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('接入设置页: 图表出现在生效曲线下方且导入后刷新', (tester) async {
    tester.view.physicalSize = const Size(1200, 3600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AudioSettingsPage()));
    await tester.pumpAndSettle();

    // 未启用 → 空态.
    expect(find.textContaining('请先导入'), findsOneWidget);

    await tester.tap(find.text('导入曲线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), sampleText);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先导入'), findsNothing);
    expect(settings.eqProfileName, '自定义曲线');
    expect(tester.takeException(), isNull);
  });
}
