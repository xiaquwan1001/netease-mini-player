/// EQ 曲线的导入校验门: 粘贴文本与"从文件读取"都必须先过 [checkEqImportText],
/// 不通过就一个字节都不落盘。
///
/// 权威校验在 Rust 侧(`eqProfileValidate` → ncm-domain 的 `EqProfile::parse`),
/// 它返回的 [rust.FfiError.detail] 本身就是 "第 N 行: 原因" 形式, 直接展示即可;
/// 本文件只做三件事: 抽取可展示文案 / FFI 不可用时按同一套规则兜底 / 拒绝空文本。
library;

import 'audio_tuning.dart' show validateEqProfile;
import 'eq_profile.dart';
import 'rust/api_all.dart' as rust;

/// 一次导入校验的结果。
class EqImportCheck {
  const EqImportCheck.passed(this.validation) : error = null;
  const EqImportCheck.failed(this.error) : validation = null;

  /// 可直接给用户看的原因(含 "第 N 行: ..."); null = 通过。
  final String? error;

  /// Rust 侧的统计(生效滤波器数 / 前级 / 峰值抬升);
  /// 纯 Dart 兜底(测试环境没加载 cdylib)时为 null。
  final rust.EqValidationDto? validation;

  bool get ok => error == null;
}

/// 校验实现(默认走 Rust 的 `eqProfileValidate`); 测试可注入替身。
typedef EqProfileValidator = Future<rust.EqValidationDto> Function(String text);

/// 校验待导入的曲线文本: 通过返回 [EqImportCheck.ok], 失败带回具体原因。
///
/// 注意顺序: 先问 Rust(三端共用的解析器, 也与真正生效的那份实现一致),
/// 只有在 FFI 根本不可用时才用 [parseParametricEq] 兜底 —— 否则两套规则各说各话。
Future<EqImportCheck> checkEqImportText(
  String text, {
  EqProfileValidator validate = validateEqProfile,
}) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const EqImportCheck.failed('请输入曲线文本');
  try {
    return EqImportCheck.passed(await validate(trimmed));
  } on rust.FfiError catch (e) {
    final detail = e.detail.trim();
    return EqImportCheck.failed(detail.isEmpty ? '曲线无法解析' : detail);
  } catch (_) {
    // 没加载 cdylib(纯 Dart 测试环境/平台不支持 FFI): 用同一套规则的 Dart 解析兜底
    try {
      parseParametricEq(trimmed);
      return const EqImportCheck.passed(null);
    } on EqProfileException catch (e) {
      return EqImportCheck.failed(e.message);
    }
  }
}
