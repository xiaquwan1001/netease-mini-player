import 'rust/api.dart' as rust;

import 'app_settings.dart';

/// 把 AppSettings 里的播放参数(R2/R5/R7)翻成一次 FFI 调用。
///
/// 单独抽成无副作用的纯函数, 便于单测"设置值 → 请求参数"的映射;
/// 真正调用 Rust 的 [applyAudioTuning] 在 Linux 桌面与 Android 上都能跑
/// (Android 由 Media3 侧消费同一份设置, 见 PlaybackService)。
class AudioTuningRequest {
  const AudioTuningRequest({
    required this.gainDb,
    required this.fadeMs,
    required this.eqText,
  });

  /// 精细音量(dB, -40..=0)
  final double gainDb;

  /// 淡入时长(ms)
  final int fadeMs;

  /// AutoEQ 曲线原文; null = 旁路
  final String? eqText;

  /// 从设置快照构造(空串/纯空白统一归一成 null, 避免 Rust 侧解析出空曲线)
  factory AudioTuningRequest.fromSettings(AppSettings s) {
    final text = s.eqProfileText?.trim();
    return AudioTuningRequest(
      gainDb: s.volumeGainDb.clamp(-40.0, 0.0),
      fadeMs: s.fadeMs,
      eqText: (text == null || text.isEmpty) ? null : s.eqProfileText,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioTuningRequest &&
      other.gainDb == gainDb &&
      other.fadeMs == fadeMs &&
      other.eqText == eqText;

  @override
  int get hashCode => Object.hash(gainDb, fadeMs, eqText);

  @override
  String toString() => 'AudioTuningRequest(gain=$gainDb dB, fade=$fadeMs ms)';
}

/// 曲线校验(R7 导入时用): 成功返回生效滤波器数, 失败抛出带 "第 N 行" 的错误。
Future<rust.EqValidationDto> validateEqProfile(String text) =>
    rust.eqProfileValidate(text: text);

/// 把当前设置的播放参数应用到 Rust 播放器。
///
/// 失败不抛给调用方: 播放参数属于"锦上添花", 不能因为它把播放/启动流程打断。
Future<void> applyAudioTuning() async {
  final request = AudioTuningRequest.fromSettings(AppSettings.instance);
  try {
    await rust.playerConfigure(
      gainDb: request.gainDb,
      fadeMs: request.fadeMs,
      eqText: request.eqText,
    );
  } catch (_) {
    // Rust core 未初始化(如 Linux 首次启动失败)时静默跳过
  }
}

/// 按设置里的上限收敛音频缓存(R5)。[keepTrackId] = 正在播放的曲目, 永不删除。
Future<void> enforceCacheLimit({int? keepTrackId}) async {
  final settings = AppSettings.instance;
  if (settings.cacheLimitMb <= 0) return;
  try {
    await rust.cacheEnforceLimit(
      limitMb: settings.cacheLimitMb,
      keepTrackId: keepTrackId == null ? null : BigInt.from(keepTrackId),
    );
  } catch (_) {
    // 同上: 缓存清理失败不影响播放
  }
}
