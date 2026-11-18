import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/eq_import.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// N1: EQ 导入的校验门(粘贴文本 / 从文件读取共用同一个入口)。
///
/// 这里注入 validator 替身: 真 FFI 路径在 eq_import_flow_test.dart 里用
/// RustLib.initMock 覆盖, 纯 Dart 兜底路径在这里锁死。
void main() {
  const goodText =
      'Preamp: -6.0 dB\n'
      'Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.71';

  test('空文本不校验也不通过', () async {
    var called = 0;
    final check = await checkEqImportText(
      '   ',
      validate: (text) async {
        called++;
        throw StateError('不该被调用');
      },
    );
    expect(check.ok, isFalse);
    expect(check.error, '请输入曲线文本');
    expect(called, 0);
  });

  test('Rust 报错: 原因原样透出(含"第 N 行"), 不吞成泛化文案', () async {
    final check = await checkEqImportText(
      goodText,
      validate: (_) async => throw const rust.FfiError(
        kind: 'internal',
        retryable: false,
        detail: '第 3 行: 不支持的滤波器类型 "LP"(只支持 PK / LS / HS)',
      ),
    );
    expect(check.ok, isFalse);
    expect(check.error, contains('第 3 行'));
    expect(check.error, contains('LP'));
    expect(check.validation, isNull);
  });

  test('通过: 带回 Rust 的统计(生效滤波器数/前级/峰值抬升)', () async {
    final check = await checkEqImportText(
      goodText,
      validate: (_) async => const rust.EqValidationDto(
        filters: 2,
        activeFilters: 1,
        preampDb: -6.0,
        maxBoostDb: -3.5,
      ),
    );
    expect(check.ok, isTrue);
    expect(check.error, isNull);
    expect(check.validation!.filters, 2);
    expect(check.validation!.activeFilters, 1);
    expect(check.validation!.preampDb, -6.0);
  });

  test('FFI 不可用(测试环境/平台无 cdylib)时按同一套 Dart 规则兜底: 合法文本通过', () async {
    final check = await checkEqImportText(
      goodText,
      validate: (_) async => throw StateError('RustLib 未初始化'),
    );
    expect(check.ok, isTrue);
    // 兜底路径没有 Rust 统计
    expect(check.validation, isNull);
  });

  test('FFI 不可用时的非法文本仍带"第 N 行"与具体字段原因', () async {
    final check = await checkEqImportText(
      'Filter 1: ON PK Fc 105 Hz Gain 30.0 dB Q 0.71',
      validate: (_) async => throw StateError('RustLib 未初始化'),
    );
    expect(check.ok, isFalse);
    expect(check.error, startsWith('第 1 行'));
    expect(check.error, contains('±24'));
  });
}
