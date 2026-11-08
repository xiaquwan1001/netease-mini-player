import 'rust/api.dart' as rust;

import 'app_settings.dart';
import 'playback.dart';

/// 把 AppSettings 里的播放参数(R2/R2b/R5/R7)翻成一次 FFI 调用。
///
/// 单独抽成无副作用的纯映射, 便于单测"设置值 → 请求参数";
/// 真正调用 Rust/Media3 的 [applyAudioTuning] 两个平台都能跑。
class AudioTuningRequest {
  const AudioTuningRequest({
    required this.gainDb,
    required this.fadeMs,
    required this.eqText,
    this.loudnessGainDb = 0.0,
  });

  /// 最终送给播放器的增益(dB): 用户精细音量 + 响度均衡增益, 钳到 -40..+12
  final double gainDb;

  /// 淡入时长(ms)
  final int fadeMs;

  /// AutoEQ 曲线原文; null = 旁路
  final String? eqText;

  /// 响度均衡给出的静态增益(RG 2.0 语义), 仅用于测试与调试回显
  final double loudnessGainDb;

  /// 从设置快照构造。
  ///
  /// [loudnessGainDb] 由 [applyLoudnessForTrack] 从测量结果算好传进来:
  /// 未开响度均衡 / 未测到 / 关闭时一律为 0(即"不改变现状")。
  factory AudioTuningRequest.fromSettings(AppSettings s, {double loudnessGainDb = 0.0}) {
    final text = s.eqProfileText?.trim();
    final loudness = s.loudnessNormalize ? loudnessGainDb : 0.0;
    return AudioTuningRequest(
      gainDb: (s.volumeGainDb + loudness).clamp(-40.0, 12.0),
      fadeMs: s.fadeMs,
      eqText: (text == null || text.isEmpty) ? null : s.eqProfileText,
      loudnessGainDb: loudness,
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

/// 平台门面(无状态: 只做通道/Rust 的分发)
final Playback _facade = Playback();

/// 每个曲目测得的响度增益缓存(避免每次切歌都过一遍 FFI)
final Map<int, double> _loudnessGainCache = <int, double>{};

/// 把当前设置的播放参数应用到播放器。
///
/// - Android: 走 Media3(S3 车道)的 `ncm/player` configure;
/// - 其它平台(Linux 桌面): 走 Rust rodio。
/// 失败不抛给调用方: 播放参数属于"锦上添花", 不能因为它把播放/启动流程打断。
Future<void> applyAudioTuning({double loudnessGainDb = 0.0}) async {
  final request = AudioTuningRequest.fromSettings(
    AppSettings.instance,
    loudnessGainDb: loudnessGainDb,
  );
  try {
    if (_facade.isAndroid) {
      // Android: Media3(S3)消费同一份参数 —— 增益乘系统音量档、淡入用 ValueAnimator、
      // 硬解/边听边存/缓存上限/EQ 由 Kotlin 侧建 player 时套用
      await _facade.applyTuning(
        gainDb: request.gainDb,
        fadeMs: request.fadeMs,
        hardwareDecode: AppSettings.instance.hardwareDecode,
        streamCache: AppSettings.instance.streamCache,
        cacheLimitMb: AppSettings.instance.cacheLimitMb,
        eqText: request.eqText,
      );
      return;
    }
    await rust.playerConfigure(
      gainDb: request.gainDb,
      fadeMs: request.fadeMs,
      eqText: request.eqText,
    );
  } catch (_) {
    // Rust core 未初始化 / 平台通道未就绪时静默跳过
  }
}

/// R2b: 为某首曲目应用响度均衡。
///
/// 顺序: 缓存命中 → 直接用; 未测且音频已缓存 → 后台测量并写 `loudness.json`;
/// 都没拿到(未缓存/未解码能力) → 按 0 dB 播放(任务书 §2.1 的验收口径)。
Future<void> applyLoudnessForTrack(int trackId) async {
  final settings = AppSettings.instance;
  if (!settings.loudnessNormalize) {
    await applyAudioTuning();
    return;
  }
  var gain = _loudnessGainCache[trackId];
  if (gain == null) {
    final target = settings.loudnessTargetLufs;
    try {
      var dto = await rust.loudnessCached(
        trackId: BigInt.from(trackId),
        targetLufs: target,
      );
      dto ??= await rust.loudnessMeasureCached(
        trackId: BigInt.from(trackId),
        targetLufs: target,
      );
      if (dto != null) gain = dto.gainDb;
    } catch (_) {
      // 测量失败(未缓存 / 该平台没有解码能力)就让这首按 0 dB 播
    }
  }
  gain ??= 0.0;
  _loudnessGainCache[trackId] = gain;
  await applyAudioTuning(loudnessGainDb: gain);
}

/// 忘记某首曲目的响度增益缓存(切换目标电平后要重算)
void forgetLoudnessGain({int? trackId}) {
  if (trackId == null) {
    _loudnessGainCache.clear();
  } else {
    _loudnessGainCache.remove(trackId);
  }
}

/// 按设置里的上限收敛音频缓存(R5)。[keepTrackId] = 正在播放的曲目, 永不删除。
Future<void> enforceCacheLimit({int? keepTrackId}) async {
  final settings = AppSettings.instance;
  if (settings.cacheLimitMb <= 0) return;
  try {
    // Android 用 Media3 的 SimpleCache + LeastRecentlyUsedCacheEvictor 自己收敛上限,
    // 这里不重复调用(两边缓存目录是隔离的, 见 PlaybackService 注释)
    if (_facade.isAndroid) return;
    await rust.cacheEnforceLimit(
      limitMb: settings.cacheLimitMb,
      keepTrackId: keepTrackId == null ? null : BigInt.from(keepTrackId),
    );
  } catch (_) {
    // 同上: 缓存清理失败不影响播放
  }
}
