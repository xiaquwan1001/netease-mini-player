import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'net_retry.dart';
import 'rust/api_all.dart' as rust;

import 'app_settings.dart';
import 'playback.dart';
import 'toast.dart';

/// 把 AppSettings 里的播放参数(R2/R2b/R5/R7)翻成一次 FFI 调用。
///
/// 单独抽成无副作用的纯映射, 便于单测"设置值 → 请求参数";
/// 真正调用 Rust/Media3 的 [applyAudioTuning] 两个平台都能跑。
class AudioTuningRequest {
  const AudioTuningRequest({
    required this.gainDb,
    required this.fadeMs,
    required this.eqText,
    this.gainSlewDbPerSec = kGainSlewDefaultDbPerSec,
    this.loudnessGainDb = 0.0,
  });

  /// 最终送给播放器的增益(dB): 用户精细音量 + 响度均衡增益, 钳到 -40..+12
  final double gainDb;

  /// 淡入时长(ms): **只作用于从暂停恢复**(2026-11-23); 切歌/首次起播不淡入
  final int fadeMs;

  /// AutoEQ 曲线原文; null = 旁路
  final String? eqText;

  /// 增益变化限速(dB/s): 0 = 瞬时, [kGainSlewDynamicDbPerSec] = 动态 AGC 防 pump。
  ///
  /// 三端同一口径(P-03): 开关只看设置里的「动态响度」, 与平台无关 —— Android 走
  /// Media3 的 ValueAnimator 斜坡, 桌面走 Rust 的 GainLimiter, 斜率值完全一样。
  final double gainSlewDbPerSec;

  /// 响度均衡给出的静态增益(RG 2.0 语义), 仅用于测试与调试回显
  final double loudnessGainDb;

  /// 从设置快照构造。
  ///
  /// [loudnessGainDb] 由 [applyLoudnessForTrack] 从测量结果算好传进来:
  /// 未开响度均衡 / 未测到 / 关闭时一律为 0(即"不改变现状")。
  factory AudioTuningRequest.fromSettings(
    AppSettings s, {
    double loudnessGainDb = 0.0,
  }) {
    final text = s.eqProfileText?.trim();
    final loudness = s.loudnessNormalize ? loudnessGainDb : 0.0;
    return AudioTuningRequest(
      gainDb: (s.volumeGainDb + loudness).clamp(-40.0, 12.0),
      fadeMs: s.fadeMs,
      eqText: (text == null || text.isEmpty) ? null : s.eqProfileText,
      gainSlewDbPerSec: gainSlewForSettings(s),
      loudnessGainDb: loudness,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AudioTuningRequest &&
      other.gainDb == gainDb &&
      other.fadeMs == fadeMs &&
      other.eqText == eqText &&
      other.gainSlewDbPerSec == gainSlewDbPerSec;

  @override
  int get hashCode => Object.hash(gainDb, fadeMs, eqText, gainSlewDbPerSec);

  @override
  String toString() =>
      'AudioTuningRequest(gain=$gainDb dB, fade=$fadeMs ms, '
      'slew=$gainSlewDbPerSec dB/s)';
}

/// 动态响度(AGC)的增益限速(dB/s): 防 pump 的验收口径(任务书 §5 "<= 3 dB/s")。
const double kGainSlewDynamicDbPerSec = 3.0;

/// 静态响度均衡/纯手动时的限速: 0 = 瞬时(拖滑杆立刻听到变化)。
const double kGainSlewDefaultDbPerSec = 0.0;

/// 设置快照 → 增益限速(dB/s)。Android 与桌面共用这一条口径(P-03)。
double gainSlewForSettings(AppSettings s) =>
    s.loudnessDynamic ? kGainSlewDynamicDbPerSec : kGainSlewDefaultDbPerSec;

/// 曲线校验(R7 导入时用): 成功返回生效滤波器数, 失败抛出带 "第 N 行" 的错误。
Future<rust.EqValidationDto> validateEqProfile(String text) =>
    rust.eqProfileValidate(text: text);

/// 平台门面(无状态: 只做通道/Rust 的分发)
final Playback _facade = Playback();

/// 每个曲目测得的响度增益缓存(避免每次切歌都过一遍 FFI)
final Map<int, double> _loudnessGainCache = <int, double>{};

/// 冷启动「播放器还没就绪」的重试退避(ms): 最多 3 次, 合计再等 1.7s。
///
/// 竞态来源(P-06): `main.dart` 的 `_bootstrap` 里 `unawaited(applyAudioTuning())`
/// 与 Android `PlaybackService` 的创建(MediaController.Builder)无任何同步, 服务
/// 还没起来时 `configure` 返回 `not_ready`; 早先这里 `catch (_) {}` 整个吞掉 ⇒
/// 用户保存的音量/淡入/EQ 一次全没落地, 连一条日志都没有。
const List<int> kTuningRetryDelaysMs = <int>[200, 500, 1000];

/// 一次调音调用是"播放器还没就绪"(值得重试)还是"真失败"。
///
/// - Android: 通道错误码 `not_ready`(MainActivity 的 configure 分支);
/// - 桌面: Rust core 还没 init 时抛的 "core not initialized"。
bool isTuningNotReady(Object error) {
  if (error is PlatformException) return error.code == 'not_ready';
  final text = error.toString().toLowerCase();
  return text.contains('not_ready') || text.contains('not initialized');
}

/// EQ 旁路是否已经提示过(同一状态只打扰一次: 播放 tick 会反复调本函数)。
bool _eqBypassNotified = false;

/// 调音最终失败是否已经提示过(冷启动连续失败同样只提示一次)。
bool _tuningFailureNotified = false;

/// 测试用: 清掉"已经提示过"的去重状态。
@visibleForTesting
void resetAudioTuningNotices() {
  _eqBypassNotified = false;
  _tuningFailureNotified = false;
}

/// 消费 Android `configure` 的回显(`eqApplied/eqError/eqFilters`)。
///
/// Kotlin 侧解析失败时 EQ 会被旁路(播放照常进行), 但以前 Dart 侧把回显整个丢掉,
/// 用户改了曲线"没生效"却毫无线索(P-05 立即项)。现在: logcat 打 `NCM-EQ` 前缀,
/// 并在**状态变化**时给一次 UI 提示 —— 每次 tick 都弹会把人烦死。
void _reportEqEcho(Map<String, Object?>? echo) {
  if (echo == null) return; // 桌面/老版本不回显: 无事可做
  final applied = echo['eqApplied'];
  if (applied == true) {
    if (_eqBypassNotified) {
      _eqBypassNotified = false;
      debugPrint('NCM-EQ 曲线已生效(此前被旁路)');
    }
    return;
  }
  if (applied != false) return; // 不回显 EQ 结果的老版本: 不误报
  final error = (echo['eqError'] as String?)?.trim();
  final detail = (error == null || error.isEmpty) ? '原因未知' : error;
  final filters = echo['eqFilters'];
  debugPrint('NCM-EQ 曲线未生效, 已旁路(filters=$filters): $detail');
  if (_eqBypassNotified) return;
  _eqBypassNotified = true;
  showGlobalToast('自定义响度曲线未生效: $detail', isError: true);
}

/// 真正调一次底层(不含重试/上报), 把两个平台分支与重试逻辑分开。
Future<void> _applyTuningOnce(AudioTuningRequest request) async {
  if (_facade.isAndroid) {
    // Android: Media3(S3)消费同一份参数 —— 增益乘系统音量档、淡入用 ValueAnimator、
    // 硬解/边听边存/缓存上限/EQ 由 Kotlin 侧建 player 时套用
    final echo = await _facade.applyTuning(
      gainDb: request.gainDb,
      fadeMs: request.fadeMs,
      hardwareDecode: AppSettings.instance.hardwareDecode,
      streamCache: AppSettings.instance.streamCache,
      cacheLimitMb: AppSettings.instance.cacheLimitMb,
      eqText: request.eqText,
      // 动态 AGC 才限速 3 dB/s(防 pump); 静态 RG2.0(默认)保持瞬时。
      // 桌面分支把**同一个值**交给 Rust 的 GainLimiter(P-03)。
      gainSlewDbPerSec: request.gainSlewDbPerSec,
    );
    _reportEqEcho(echo);
    return;
  }
  // 桌面(Linux/Windows): rodio + Rust 的 GainLimiter。斜率与 Android 同口径:
  // 0 = 瞬时(静态/手动), 3 dB/s = 动态 AGC 防 pump。
  await rust.playerConfigure(
    gainDb: request.gainDb,
    fadeMs: request.fadeMs,
    eqText: request.eqText,
    gainSlewDbPerSec: request.gainSlewDbPerSec,
  );
}

/// 把当前设置的播放参数应用到播放器。
///
/// - Android: 走 Media3(S3 车道)的 `ncm/player` configure;
/// - 其它平台(Linux 桌面): 走 Rust rodio。
/// 失败不抛给调用方: 播放参数属于"锦上添花", 不能因为它把播放/启动流程打断;
/// 但**不再静默** —— 冷启动竞态按 [kTuningRetryDelaysMs] 有限次重试, 仍失败则
/// 打日志 + 一次性提示, 其它异常同样留日志(P-06)。
///
/// [retryDelaysMs] 仅供测试缩短退避, 生产调用方不用传。
Future<void> applyAudioTuning({
  double loudnessGainDb = 0.0,
  List<int> retryDelaysMs = kTuningRetryDelaysMs,
}) async {
  final request = AudioTuningRequest.fromSettings(
    AppSettings.instance,
    loudnessGainDb: loudnessGainDb,
  );
  final maxAttempts = retryDelaysMs.length + 1;
  for (var attempt = 1; ; attempt++) {
    try {
      await _applyTuningOnce(request);
      _tuningFailureNotified = false;
      return;
    } catch (e) {
      final retryIndex = attempt - 1;
      if (isTuningNotReady(e) && retryIndex < retryDelaysMs.length) {
        final delayMs = retryDelaysMs[retryIndex];
        debugPrint(
          'NCM-TUNING 播放器未就绪, ${delayMs}ms 后重试($attempt/$maxAttempts)',
        );
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        continue;
      }
      // 走到这里就是最终失败: 不可重试(如通道参数错), 或重试用完
      debugPrint('NCM-TUNING 播放参数未生效($attempt/$maxAttempts): $e');
      if (!_tuningFailureNotified) {
        _tuningFailureNotified = true;
        showGlobalToast('播放参数暂未生效, 下次启动会重新应用', isError: true);
      }
      return;
    }
  }
}

/// R2b: 为某首曲目应用响度均衡。
///
/// 顺序: 缓存命中 → 直接用; 未测且音频已缓存 → 后台测量并写 `loudness.json`;
/// 都没拿到(未缓存/未解码能力) → 按 0 dB 播放(任务书 §2.1 的验收口径)。
Future<void> applyLoudnessForTrack(int trackId, {String? streamUrl}) async {
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
      // Android: 音频在 Media3 的 SimpleCache 里, 先问 Kotlin 要缓存文件路径再让 Rust 解码测量
      if (dto == null && streamUrl != null && _facade.isAndroid) {
        final path = await _facade.cachedAudioFile(streamUrl);
        if (path == null) {
          debugPrint('[R2b] 播放中还没有可测的缓存文件 track=$trackId');
        } else {
          dto = await rust.loudnessMeasurePath(
            trackId: BigInt.from(trackId),
            path: path,
            targetLufs: target,
            formatHint: _formatHintFromUrl(streamUrl),
          );
        }
      }
      dto ??= await rust.loudnessMeasureCached(
        trackId: BigInt.from(trackId),
        targetLufs: target,
      );
      if (dto != null) {
        gain = dto.gainDb;
      } else {
        debugPrint('[R2b] 未拿到测量结果 track=$trackId(先按 0 dB 播)');
      }
    } catch (e) {
      // 测量失败(未缓存 / 解码失败)就让这首按 0 dB 播, 但要留下可查的日志
      debugPrint('[R2b] 测量失败 track=$trackId: ${describeError(e)}');
    }
  }
  // 只有真的测到才记进缓存: 否则 0 dB 会被当成"已知", 之后的补测就不会再发生了
  if (gain != null) _loudnessGainCache[trackId] = gain;
  await applyAudioTuning(loudnessGainDb: gain ?? 0.0);
}

/// Media3 缓存文件没有扩展名, symphonia 的 m4a/mp4 解封装需要扩展名提示 ⇒ 从直链里猜
String? _formatHintFromUrl(String url) {
  for (final ext in const ['mp3', 'flac', 'm4a', 'mp4', 'ogg', 'wav']) {
    if (url.toLowerCase().contains('.$ext')) return ext;
  }
  return null;
}

/// 某首曲目的响度增益是否已经算出来过(用于"还没测到就隔一会儿再试")
bool hasLoudnessGain(int trackId) => _loudnessGainCache.containsKey(trackId);

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
