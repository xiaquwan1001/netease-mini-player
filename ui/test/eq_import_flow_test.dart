import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/eq_curve_chart.dart';
import 'package:minincm/src/eq_profile.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/settings_audio_page.dart';

/// N1: 设置页「自定义响度曲线」的导入链路 + 图表高度。
///
/// 导入必须过 Rust 的 eqProfileValidate(唯一入口是 audio_tuning.validateEqProfile);
/// 这里用 RustLib.initMock 注入替身, 断言「不通过不落盘 + 回显行号」与「通过才写
/// AppSettings」。initMock 每个进程只能调一次(flutter_rust_bridge 的
/// `Should not initialize flutter_rust_bridge twice`), 所以替身是全局单实例 +
/// 每个用例重置行为。
class _FakeEqApi implements RustLibApi {
  /// 非空 = 让 eqProfileValidate 抛 FfiError(模拟 Rust 侧解析失败)
  String? errorDetail;

  final List<String> validated = <String>[];

  void reset() {
    errorDetail = null;
    validated.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<rust.EqValidationDto> crateApiPlaybackEqProfileValidate({
    required String text,
  }) async {
    validated.add(text);
    final detail = errorDetail;
    if (detail != null) {
      throw rust.FfiError(kind: 'internal', retryable: false, detail: detail);
    }
    // 用同一份 Dart 解析算统计, 保证「生效 N 个」的断言有确定值
    final eq = parseParametricEq(text);
    return rust.EqValidationDto(
      filters: eq.filters.length,
      activeFilters: eq.filters
          .where((f) => f.enabled && f.gainDb.abs() > 1e-6)
          .length,
      preampDb: eq.preampDb,
      maxBoostDb: eq.preampDb,
    );
  }
}

void main() {
  final api = _FakeEqApi();
  RustLib.initMock(api: api);

  final settings = AppSettings.instance;

  late String? eqProfileText;
  late String? eqProfileName;

  setUp(() {
    api.reset();
    eqProfileText = settings.eqProfileText;
    eqProfileName = settings.eqProfileName;
  });

  tearDown(() {
    settings.eqProfileText = eqProfileText;
    settings.eqProfileName = eqProfileName;
    settings.notifyListeners();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: AudioSettingsPage()));
    await tester.pumpAndSettle();
  }

  testWidgets('校验不通过: 对话框内回显"第 N 行", 且不写 AppSettings', (tester) async {
    await pumpPage(tester);
    api.errorDetail = '第 2 行: 不支持的滤波器类型 "LP"(只支持 PK / LS / HS)';

    final before = settings.eqProfileText;
    await tester.tap(find.text('导入曲线'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'Preamp: 0.0 dB\n'
      'Filter 1: ON LP Fc 105 Hz Gain -3.2 dB Q 0.71',
    );
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 现成的错误行样式(对话框内红字)回显具体原因
    expect(find.textContaining('第 2 行'), findsOneWidget);
    expect(find.textContaining('不支持的滤波器类型'), findsOneWidget);
    // 对话框没关, 设置也没被覆盖
    expect(find.text('导入响度曲线'), findsOneWidget);
    expect(settings.eqProfileText, before);
    expect(api.validated, hasLength(1));
  });

  testWidgets('校验通过才应用: 写回文本并提示生效滤波器数', (tester) async {
    await pumpPage(tester);

    const text =
        'Preamp: -6.0 dB\n'
        'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71\n'
        'Filter 2: OFF PK Fc 120 Hz Gain 2.5 dB Q 0.70';
    await tester.tap(find.text('导入曲线'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(settings.eqProfileText, text);
    expect(settings.eqProfileName, '自定义曲线');
    // OFF 的那根不算生效, 所以是 1 个
    expect(find.text('已导入自定义响度曲线(生效 1 个滤波器)'), findsOneWidget);
    // 弹窗校验一次 + 落盘边界(唯一写入口)再校验一次, 两次都过才写
    expect(api.validated, hasLength(2));
    expect(api.validated.every((t) => t == text), isTrue);
  });

  testWidgets('图表高度 = 旧基数 × 1.15, 曲线/柱状两视图同高', (tester) async {
    await pumpPage(tester);

    final panel = tester.getSize(find.byType(EqCurvePanel));
    expect(panel.height, kEqPanelHeight);
    // 用比例断言, 不把 266.8 再写一遍
    expect(
      panel.height / kEqPanelBaseHeight,
      closeTo(kEqChartHeightScale, 1e-9),
    );

    await tester.tap(find.text('柱状'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(EqCurvePanel)).height, kEqPanelHeight);
    expect(tester.takeException(), isNull);
  });
}
