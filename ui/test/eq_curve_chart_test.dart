import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/eq_curve_chart.dart';
import 'package:minincm/src/eq_profile.dart';
import 'package:minincm/src/settings_audio_page.dart';

const sampleText =
    'Preamp: -6.0 dB\n'
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
                onChanged: (t) =>
                    settings.update(eqProfileText: t, eqProfileName: '自定义曲线'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空态: 回退到默认曲线(10 段全 0), 可直接拖柱', (tester) async {
    await pumpPanel(tester, text: null);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('柱状'));
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byType(EqCurvePanel));
    final colW = size.width / 10;
    final gesture = await tester.startGesture(Offset(colW * 3.5, 232 / 2));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final eq = parseOk(settings.eqProfileText!);
    expect(eq.filters.length, 10);
    // 第 4 根柱(250 Hz)被抬起, 其余仍为 0.
    final changed = eq.filters.firstWhere((f) => f.gainDb != 0);
    expect(changed.freqHz, 250);
    expect(eq.filters.where((f) => f.gainDb == 0).length, 9);
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
    await pumpPanel(
      tester,
      text: 'Preamp: -6.0 dB\nFilter 1: ON LP Fc 100 Hz Gain 1 dB Q 0.7',
    );
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
    settings.eqProfileText =
        'Preamp: 0.0 dB\nFilter 1: ON PK Fc 100 Hz Gain 4.0 dB Q 0.7';
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
    final gesture = await tester.startGesture(
      Offset(size.width / 2, size.height / 2),
    );
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

    // 未启用 → 自动生成默认曲线(10 段全 0 dB).
    expect(find.text('生效曲线'), findsOneWidget);
    expect(find.text('默认曲线(10 段, 全 0 dB)'), findsOneWidget);
    expect(settings.eqProfileText, isNotNull);
    final eq0 = parseOk(settings.eqProfileText!);
    expect(eq0.filters.length, 10);
    expect(eq0.preampDb, 0.0);
    expect(eq0.filters.every((f) => f.gainDb == 0.0), isTrue);
    expect(settings.eqProfileName, '默认曲线');

    await tester.tap(find.text('导入曲线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), sampleText);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('请先导入'), findsNothing);
    expect(settings.eqProfileName, '自定义曲线');
    expect(tester.takeException(), isNull);
  });

  group('默认曲线与重置', () {
    test('defaultEqProfileText: 10 段 PK 全 0, Preamp 0, 可往返解析', () {
      final eq = parseOk(defaultEqProfileText());
      expect(eq.filters.length, 10);
      expect(eq.preampDb, 0.0);
      expect(
        eq.filters.map((f) => f.freqHz).toList(),
        defaultEqBandFrequencies,
      );
      expect(
        eq.filters.every(
          (f) => f.gainDb == 0.0 && f.type == EqFilterType.pk && f.q == 1.0,
        ),
        isTrue,
      );
      // 全 0 dB 等价旁路: 任意频点响应均为 0 dB.
      for (final f in [20.0, 500.0, 1000.0, 8000.0, 16000.0]) {
        expect(evaluateEqDb(eq, [f]).first, closeTo(0.0, 1e-9));
      }
    });

    testWidgets('无 profile 拖柱: 文本写回, 只有目标段变化', (tester) async {
      settings.eqProfileText = null;
      settings.eqProfileName = null;
      settings.notifyListeners();
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AudioSettingsPage()));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('柱状'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('柱状'), warnIfMissed: true);
      await tester.pumpAndSettle();
      // 确认已切到柱状视图: 当前 EqCurvePanel 子树不再有曲线路径, 改为
      // 拖动后检查写回结果(柱状标注是画布文本, 无 Text widget 可查).
      final size = tester.getSize(find.byType(EqCurvePanel));
      final colW = size.width / 10;
      await tester.ensureVisible(find.byType(EqCurvePanel));
      await tester.pumpAndSettle();
      final origin2 = tester.getTopLeft(find.byType(EqCurvePanel));
      final gesture = await tester.startGesture(
        origin2 + Offset(colW * 6.5, 232 / 2),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, -60));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();

      final eq = parseOk(settings.eqProfileText!);
      final nonZero = eq.filters.where((f) => f.gainDb != 0).toList();
      expect(nonZero.length, 1);
      expect(nonZero.first.freqHz, 2000);
      expect(nonZero.first.gainDb, greaterThan(0));
      expect(eq.preampDb, 0.0);
    });

    testWidgets('已有自定义 profile: 进入页面不覆盖', (tester) async {
      settings.eqProfileText = sampleText;
      settings.eqProfileName = '自定义曲线';
      settings.notifyListeners();
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AudioSettingsPage()));
      await tester.pumpAndSettle();

      expect(settings.eqProfileText, sampleText);
      expect(settings.eqProfileName, '自定义曲线');
      expect(find.text('自定义曲线'), findsOneWidget);
    });

    testWidgets('重置为默认: 文本回 10 段全 0 且名称变化', (tester) async {
      settings.eqProfileText = sampleText;
      settings.eqProfileName = '自定义曲线';
      settings.notifyListeners();
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AudioSettingsPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('重置为默认'));
      await tester.pumpAndSettle();

      final eq = parseOk(settings.eqProfileText!);
      expect(eq.filters.length, 10);
      expect(eq.preampDb, 0.0);
      expect(eq.filters.every((f) => f.gainDb == 0.0), isTrue);
      expect(settings.eqProfileName, '默认曲线');
    });

    testWidgets('导出: 复制内容与当前文本一致(往返)', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
      });
      settings.eqProfileText = sampleText;
      settings.eqProfileName = '自定义曲线';
      settings.notifyListeners();
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: AudioSettingsPage()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('导出曲线'));
      await tester.pumpAndSettle();
      expect(copied, sampleText);
      // 往返: 导出的文本能解析回相同曲线.
      final eq1 = parseOk(sampleText);
      final eq2 = parseOk(copied!);
      expect(eq2.filters.length, eq1.filters.length);
      expect(eq2.preampDb, eq1.preampDb);
    });
  });
}
