import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/eq_profile.dart';
import 'package:minincm/src/settings_audio_page.dart';

/// S5: 设置页「播放与音质」二级页的字段写回测试(R2/R2b/R5/R7).
void main() {
  final settings = AppSettings.instance;

  double volumeGainDb = 0;
  bool loudnessNormalize = false;
  double loudnessTargetLufs = -16;
  bool loudnessDynamic = false;
  int fadeMs = 0;
  bool streamCache = true;
  int cacheLimitMb = 512;
  String? eqProfileName;
  String? eqProfileText;

  setUp(() {
    volumeGainDb = settings.volumeGainDb;
    loudnessNormalize = settings.loudnessNormalize;
    loudnessTargetLufs = settings.loudnessTargetLufs;
    loudnessDynamic = settings.loudnessDynamic;
    fadeMs = settings.fadeMs;
    streamCache = settings.streamCache;
    cacheLimitMb = settings.cacheLimitMb;
    eqProfileName = settings.eqProfileName;
    eqProfileText = settings.eqProfileText;
  });

  tearDown(() {
    settings.volumeGainDb = volumeGainDb;
    settings.loudnessNormalize = loudnessNormalize;
    settings.loudnessTargetLufs = loudnessTargetLufs;
    settings.loudnessDynamic = loudnessDynamic;
    settings.fadeMs = fadeMs;
    settings.streamCache = streamCache;
    settings.cacheLimitMb = cacheLimitMb;
    settings.eqProfileName = eqProfileName;
    settings.eqProfileText = eqProfileText;
    settings.notifyListeners();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AudioSettingsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('精细音量: 0 dB 显示不变, 拖动写回 volumeGainDb 并显示 dB', (tester) async {
    await pumpPage(tester);
    expect(find.text('不变'), findsOneWidget);
    expect(find.text('与系统音量相乘, 不影响系统音量本身。'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byKey(const Key('volumeGainSlider')));
    slider.onChanged!(-12.5);
    await tester.pump();
    expect(settings.volumeGainDb, -12.5);
    expect(find.text('-12.5 dB'), findsOneWidget);
  });

  testWidgets('响度均衡: 开关写回 loudnessNormalize 并解锁动态 AGC', (tester) async {
    await pumpPage(tester);
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('loudnessDynamicSwitch'))).onChanged,
      isNull,
    );

    await tester.tap(find.byKey(const Key('loudnessNormalizeSwitch')));
    await tester.pumpAndSettle();
    expect(settings.loudnessNormalize, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byKey(const Key('loudnessDynamicSwitch'))).onChanged,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('loudnessDynamicSwitch')));
    await tester.pumpAndSettle();
    expect(settings.loudnessDynamic, isTrue);
  });

  testWidgets('目标电平下拉写回 loudnessTargetLufs', (tester) async {
    await pumpPage(tester);
    final dd = tester.widget<DropdownButton<double>>(
      find.byKey(const Key('loudnessTargetDropdown')),
    );
    dd.onChanged!(-14.0);
    await tester.pump();
    expect(settings.loudnessTargetLufs, -14.0);
  });

  testWidgets('淡入淡出下拉写回 fadeMs', (tester) async {
    await pumpPage(tester);
    final dd = tester.widget<DropdownButton<int>>(find.byKey(const Key('fadeDropdown')));
    dd.onChanged!(500);
    await tester.pump();
    expect(settings.fadeMs, 500);
  });

  testWidgets('边听边存开关与缓存上限写回', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const Key('streamCacheSwitch')));
    await tester.pumpAndSettle();
    expect(settings.streamCache, isFalse);

    final dd = tester.widget<DropdownButton<int>>(find.byKey(const Key('cacheLimitDropdown')));
    dd.onChanged!(2048);
    await tester.pump();
    expect(settings.cacheLimitMb, 2048);
  });

  testWidgets('Linux 下不显示"优先硬件解码"项', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const Key('hardwareDecodeSwitch')), findsNothing);
    expect(find.text('优先硬件解码'), findsNothing);
    expect(find.textContaining('纯软解'), findsOneWidget);
  });

  testWidgets('导入非法曲线: 弹窗内报第 N 行且不写 AppSettings', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('导入曲线'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'Filter 1: ON PK Fc 105 Hz Gain 30.0 dB Q 0.71',
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('第 1 行'), findsOneWidget);
    expect(find.textContaining('±24'), findsOneWidget);
    // 进入页面已自动生成默认曲线, 非法导入不覆盖它.
    final eq = parseParametricEq(settings.eqProfileText!);
    expect(eq.filters.length, 10);
    expect(eq.filters.every((f) => f.gainDb == 0.0), isTrue);
  });

  testWidgets('导入合法曲线: 写回 eqProfileText/eqProfileName', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('导入曲线'));
    await tester.pumpAndSettle();

    const text = 'Preamp: -6.0 dB\n'
        'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\n'
        'Filter 2: ON LS Fc 120 Hz Gain 2.5 dB Q 0.70';
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(settings.eqProfileName, '自定义曲线');
    expect(settings.eqProfileText, text);
    expect(find.text('自定义曲线'), findsOneWidget);
  });

  testWidgets('导出: 复制原文并提示行数(与导入往返一致)', (tester) async {
    settings.eqProfileName = '自定义曲线';
    settings.eqProfileText = 'Preamp: -6.0 dB\n'
        'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71';
    settings.notifyListeners();

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
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await pumpPage(tester);
    await tester.tap(find.text('导出曲线'));
    await tester.pumpAndSettle();

    expect(copied, settings.eqProfileText);
    expect(find.text('已复制 2 行'), findsOneWidget);
  });

  testWidgets('重置为默认: 文本回 10 段全 0, 名称变为默认曲线', (tester) async {
    settings.eqProfileName = '自定义曲线';
    settings.eqProfileText = 'Preamp: 0.0 dB\n'
        'Filter 1: ON PK Fc 100 Hz Gain -1.0 dB Q 0.7';
    settings.notifyListeners();

    await pumpPage(tester);
    expect(find.text('自定义曲线'), findsOneWidget);

    await tester.tap(find.text('重置为默认'));
    await tester.pumpAndSettle();

    expect(settings.eqProfileName, '默认曲线');
    final eq = parseParametricEq(settings.eqProfileText!);
    expect(eq.filters.length, 10);
    expect(eq.filters.every((f) => f.gainDb == 0.0), isTrue);
    expect(find.text('默认曲线(10 段, 全 0 dB)'), findsOneWidget);
  });
}
