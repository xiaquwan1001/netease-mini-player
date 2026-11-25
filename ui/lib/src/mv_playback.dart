import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart' show AppSettings, AudioFocusPolicy;
import 'platform.dart';
import 'platform_is.dart' show isAndroidPlatform;
import 'playback.dart';

/// MV 起播前对歌曲的处理决策(纯函数, 单测覆盖; 见 [MvPlayback.duckSong])。
enum MvSongDuckPlan {
  /// 歌曲没在播: 什么都不用做
  none,

  /// 歌曲在播: 先暂停
  pause,
}

/// 起播 MV 前「要不要让歌曲让路」(U-04)。
///
/// 只有歌曲**真的在播**才暂停 —— 用户可能只是点开 MV 页看评论, 点"播放"才是真起播,
/// 不能因为打开了页面就无声地把他的播放停掉。判断放在这里是为了可单测。
MvSongDuckPlan mvDuckPlan({required bool songPlaying}) =>
    songPlaying ? MvSongDuckPlan.pause : MvSongDuckPlan.none;

/// 让歌曲让路时用哪种暂停。
///
/// - [fade]: 淡出后停 —— `pause` 通道立刻返回, 真正的 `pause()` 在 `fadeMs` 之后;
/// - [immediate]: 立即静音暂停, 不走淡出。
enum MvSongPauseMode { fade, immediate }

/// 当前焦点档位下该用哪一种暂停(纯函数, 单测覆盖)。
///
/// 审计 U3(2026-11-25): 只有「总是在后台播放」要立即停, 理由不是体验而是**没有兜底**:
/// 该档 MV **不申请音频焦点**(Kotlin `AudioFocusPolicy.mvRequestsFocus`),
/// 另外两档 MV 会抢焦点 ⇒ 歌曲的 ExoPlayer(跟随系统)或服务的焦点监听(总是停止)
/// 收到 LOSS 后立刻停, 淡出只是被提前打断, 不存在双声窗口。这一档若也走淡出,
/// `pause` 通道立刻返回而真正的 `pause()` 在 fadeMs(≤5s)之后 ⇒ 这一整段 MV 与歌曲双声。
MvSongPauseMode mvSongPauseMode(AudioFocusPolicy focusMode) =>
    focusMode == AudioFocusPolicy.alwaysPlay
    ? MvSongPauseMode.immediate
    : MvSongPauseMode.fade;

/// 从 MV 返回后的动作。
enum MvReturnPlan {
  /// 之前没暂停过歌曲 / 无需任何处理
  nothing,

  /// 保持暂停, 给一条"要接着听点播放条"的提示(默认口径)
  hintManualResume,

  /// 自动恢复播放([autoResumeEnabled] 打开时才可能走到)
  autoResume,
}

/// 从 MV 返回后的恢复策略(纯函数, 单测覆盖)。
///
/// 默认口径(2026-11-18 U-04 裁决): **不自动恢复** —— MV 播放是独立全屏 Activity,
/// 用户按返回多半是"看完了/顺手退出", 这时自动出声可能打断他(正在说话、已经切去别处);
/// 恢复交给常驻播放条手动点。保留 [autoResumeEnabled] 是为了让"要不要自动恢复"是
/// 一个可测的显式开关, 而不是散在注释里的隐性约定。
MvReturnPlan mvReturnPlan({
  required bool songWasDucked,
  bool autoResumeEnabled = false,
}) {
  if (!songWasDucked) return MvReturnPlan.nothing;
  return autoResumeEnabled
      ? MvReturnPlan.autoResume
      : MvReturnPlan.hintManualResume;
}

/// 歌曲侧的三个动作(MV 起播前让路用)。抽成接口是为了单测注入假实现;
/// 生产实现 [PlaybackSongGate] 走 [Playback] 门面(Android=Media3, 桌面=Rust)。
abstract class MvSongGate {
  const MvSongGate();

  /// 当前歌曲是否在播
  Future<bool> isPlaying();

  /// 暂停歌曲(调用前应确认在播)。淡出语义: 通道立刻返回, 真正停在 `fadeMs` 之后。
  Future<void> pause();

  /// 立即静音暂停(不走淡出), 用于没有焦点兜底的档位(见 [mvSongPauseMode])。
  ///
  /// 默认实现回落 [pause](淡出): 新增这个能力时不打破已有的实现者;
  /// 真正能"现在就必须安静"的只有生产门面 [PlaybackSongGate]。
  Future<void> pauseImmediately() => pause();

  /// 恢复歌曲
  Future<void> resume();
}

/// 生产实现: 读/控真实的播放器([Playback().state]/[Playback().pause]/[Playback().resume])。
class PlaybackSongGate extends MvSongGate {
  const PlaybackSongGate();

  @override
  Future<bool> isPlaying() async => (await Playback().state()).playing;

  @override
  Future<void> pause() => Playback().pause();

  @override
  Future<void> pauseImmediately() => Playback().pauseImmediately();

  @override
  Future<void> resume() => Playback().resume();
}

/// MV 播放通道: Android 走 `ncm/mv` MethodChannel 起独立 VideoView Activity;
/// 其他平台(Linux 桌面)没有内嵌视频能力, 用系统播放器/浏览器打开直链。
class MvPlayback {
  MvPlayback({
    MethodChannel? channel,
    this.playOverride,
    MvSongGate? songGate,
    AudioFocusPolicy Function()? focusMode,
  }) : _channel = channel ?? const MethodChannel('ncm/mv'),
       songGate = songGate ?? const PlaybackSongGate(),
       focusMode = focusMode ?? _configuredFocusMode;

  final MethodChannel _channel;

  /// 歌曲侧接口(MV 起播前让路; 测试可注入)
  final MvSongGate songGate;

  /// 当前音频焦点档位: 决定 MV 起播前用淡出还是立即暂停(见 [mvSongPauseMode])。
  /// 默认读设置单例, 测试注入固定档位。
  final AudioFocusPolicy Function() focusMode;

  /// 默认(生产)档位来源
  static AudioFocusPolicy _configuredFocusMode() =>
      AppSettings.instance.audioFocus;

  /// 测试注入: 直接接管 play(不触平台通道)
  final Future<void> Function(String url, String title)? playOverride;

  /// Android 是否支持内嵌播放(决定 UI 显示「播放」还是「外链」)
  bool get supportsInlinePlayback => isAndroidPlatform;

  /// 起播前让歌曲让路(U-04): 需要时暂停歌曲, 返回「之前是否真的在播(即真暂停过)」。
  ///
  /// 这是**体验层**的一层: 返回 MV 页后默认不自动恢复(见 [mvReturnPlan])。
  /// 原生侧还有一层兜底: MvPlayerActivity 申请音频焦点, 歌曲 ExoPlayer 打开了
  /// handleAudioFocus ⇒ 即使这里暂停失败/漏掉, 歌曲也会被系统焦点压停。
  /// 「总是在后台播放」档没有这层兜底, 所以那一档必须立即停(见 [mvSongPauseMode])。
  Future<bool> duckSong() async {
    final bool playing;
    try {
      playing = await songGate.isPlaying();
    } catch (e) {
      debugPrint('[NCM-MV] 读歌曲播放状态失败(按「未在播」处理): $e');
      return false;
    }
    if (mvDuckPlan(songPlaying: playing) == MvSongDuckPlan.none) return false;
    final pauseMode = mvSongPauseMode(focusMode());
    try {
      switch (pauseMode) {
        case MvSongPauseMode.immediate:
          await songGate.pauseImmediately();
        case MvSongPauseMode.fade:
          await songGate.pause();
      }
    } catch (e) {
      debugPrint('[NCM-MV] 暂停歌曲失败(MV 起播后由音频焦点兜底): $e');
      return false;
    }
    debugPrint(
      '[NCM-MV] 歌曲正在播 ⇒ 起播 MV 前已暂停'
      '(${pauseMode == MvSongPauseMode.immediate ? '立即' : '淡出'}, 返回后不自动恢复)',
    );
    return true;
  }

  /// 把 [duckSong] 刚暂停的歌曲放回播放(MV 起播失败时用)。
  Future<void> unduckSong() async {
    try {
      await songGate.resume();
    } catch (e) {
      debugPrint('[NCM-MV] 恢复歌曲失败(用户可点播放条手动续播): $e');
    }
  }

  /// 播放 MV 直链. [url] 必须是 https 直链(取链后即播, 直链 1 小时过期)。
  ///
  /// 不在这里自动 [duckSong]: 调用方([MvPage])要先拿到"是否暂停过"来决定
  /// 起播失败时要不要回滚, 且提示文案归页面管。
  Future<void> play(String url, String title) async {
    if (playOverride != null) return playOverride!(url, title);
    if (url.isEmpty) throw Exception('MV 链接为空');
    if (supportsInlinePlayback) {
      await _channel.invokeMethod<void>('play', {'url': url, 'title': title});
      return;
    }
    await PlatformBridge.openUrl(url);
  }
}
