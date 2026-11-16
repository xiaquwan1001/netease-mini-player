import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';

import 'rust/api.dart' as rust;

/// UI 用的播放状态(与 Rust/Android 两侧统一)
class PlayerView {
  const PlayerView({
    this.trackId,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.volume,
  });

  final BigInt? trackId;
  final bool playing;
  final BigInt positionMs;
  final BigInt durationMs;
  final double volume;

  static final empty = PlayerView(
    playing: false,
    positionMs: BigInt.zero,
    durationMs: BigInt.zero,
    volume: 1.0,
  );
}

/// 网易 CDN 直链默认是明文 http；模拟器 NAT / 公司网 / 部分运营商只放行 443,
/// 明文 80 会被中间设备回 502(空 body), ExoPlayer 侧表现为
/// "None of the available extractors could read the stream" 的假解码错误。
/// CDN 同路径支持 https(证书覆盖 *.music.126.net), Android 边拉边播统一升级到 https。
/// 纯函数, 方便单测。
String preferHttpsStreamUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return url;
  return uri.replace(scheme: 'https').toString();
}

/// 播放门面: Android 走 Media3(Kotlin), 其它平台走 Rust core.
/// 规则: 平台差异只允许出现在这一层, UI 不感知.
class Playback {
  static const _channel = MethodChannel('ncm/player');

  /// 测试专用: host 上 Platform.isAndroid 恒为 false, 置 true 可强制走 Android 分支
  @visibleForTesting
  static bool debugForceAndroid = false;

  bool get isAndroid => Platform.isAndroid || debugForceAndroid;

  static bool get _isAndroidPlatform => Platform.isAndroid || debugForceAndroid;

  /// 通知按钮(红心/模式)最近一次**成功**推送的状态。
  ///
  /// 两个用途(见 P-02):
  /// 1) 幂等: 值没变就不重复跨通道(轮询里的定时重推靠这里短路成一次内存比较);
  /// 2) 自愈: 原生服务被系统回收重建后, 通知图标会回到默认值, 原生会请求重推,
  ///    这里能立刻用"最近已知状态"补一次, 不必等用户切歌。
  static bool? _sentLiked;
  static String? _sentModeIcon;

  /// 测试用: 清掉幂等/自愈缓存(生产路径由原生 syncActionState 请求来清)
  @visibleForTesting
  static void debugResetActionStateCache() {
    _sentLiked = null;
    _sentModeIcon = null;
    _pendingNativeActions.clear();
  }

  // 原生 → Dart 的单向回调(通知栏/耳机键/蓝牙都只发意图, 逻辑在 Dart):
  // 两条注册入口共用一个 handler, 后注册的不会把先注册的覆盖掉.
  static void Function()? _onNext;
  static void Function()? _onPrevious;
  static void Function()? _onToggleLike;
  static void Function()? _onCycleMode;
  static void Function()? _onEnded;

  /// 通知栏/耳机键/蓝牙的上一首·下一首回调.
  /// 原生侧(ForwardingPlayer)只发意图, 真正的换曲在 Dart 队列里做 —— 队列只有一份.
  static void setSkipHandlers({
    void Function()? onNext,
    void Function()? onPrevious,
    void Function()? onEnded,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
    _onEnded = onEnded;
    _registerNativeHandler();
  }

  /// 通知栏自定义按钮(喜欢/播放顺序)的回调: 原生只发意图, 状态与副作用全在 Dart.
  static void setActionHandlers({
    void Function()? onToggleLike,
    void Function()? onCycleMode,
  }) {
    _onToggleLike = onToggleLike;
    _onCycleMode = onCycleMode;
    _registerNativeHandler();
  }

  /// 原生动作名 → Dart 回调. 未注册的回调返回 null(动作进排队区, 注册后补执行).
  static void Function()? _handlerOf(String method) => switch (method) {
    'skipNext' => _onNext,
    'skipPrevious' => _onPrevious,
    'toggleLike' => _onToggleLike,
    'cycleMode' => _onCycleMode,
    'trackEnded' => _onEnded,
    _ => null,
  };

  /// 能识别的原生动作名(其余名字不排队, 只打日志: 多半是两端口径漂了)
  static const Set<String> _nativeActions = <String>{
    'skipNext',
    'skipPrevious',
    'toggleLike',
    'cycleMode',
    'trackEnded',
  };

  /// 回调还没注册时到达的原生动作(握手比 [setActionHandlers] 先到的那几微秒).
  /// 以前这里 `_onToggleLike?.call()` 会静默丢掉点击, 现在按到达顺序排队, 注册后补执行。
  static final List<String> _pendingNativeActions = <String>[];

  static const int _maxPendingNativeActions = 8;

  static void _registerNativeHandler() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'syncActionState') {
        _resyncActionState();
        return null;
      }
      final handler = _handlerOf(call.method);
      if (handler != null) {
        handler();
      } else if (_nativeActions.contains(call.method)) {
        if (_pendingNativeActions.length >= _maxPendingNativeActions) {
          _pendingNativeActions.removeAt(0);
        }
        _pendingNativeActions.add(call.method);
        debugPrint('[NCM-PLAYER] 原生动作 ${call.method} 到达时回调未注册, 排队');
      } else {
        debugPrint('[NCM-PLAYER] 未知的原生动作: ${call.method}');
      }
      return null;
    });
    // 先补执行排队中的动作(setSkipHandlers 会先注册、setActionHandlers 后来,
    // 喜欢/模式可能在中间这批里), 再握手。
    _flushPendingNativeActions();
    // 握手: 告诉原生"通知回调已注册"。上划清任务后点通知按钮时, 原生会先用 Intent 把 App
    // 拉起来并把动作排队, 收到这条握手才执行(见 MainActivity.deliverPendingPlaybackAction)。
    if (_isAndroidPlatform) {
      _channel
          .invokeMethod<void>('actionHandlersReady')
          .catchError((Object _) {});
    }
  }

  /// 按到达顺序补执行排队中的原生动作; 对应回调仍未注册就停下(保持顺序, 等下一次注册)
  static void _flushPendingNativeActions() {
    while (_pendingNativeActions.isNotEmpty) {
      final handler = _handlerOf(_pendingNativeActions.first);
      if (handler == null) return;
      _pendingNativeActions.removeAt(0);
      handler();
    }
  }

  /// 原生请求重推通知按钮状态(服务/会话重建、控制器重连): 用最近已知状态立刻补一次,
  /// 并清掉幂等缓存, 让下一轮轮询把**当前真实状态**再推一遍(失败重试也走同一条路径)。
  static void _resyncActionState() {
    final liked = _sentLiked;
    final icon = _sentModeIcon;
    _sentLiked = null;
    _sentModeIcon = null;
    debugPrint('[NCM-PLAYER] 原生请求重推通知按钮状态(liked=$liked icon=$icon)');
    if (liked != null && icon != null) {
      unawaited(Playback().setActionState(liked: liked, modeIcon: icon));
    }
  }

  /// Dart → 原生: 通知自定义按钮的状态(红心实/空 + 模式图标), 原生据此重设按钮并刷新通知.
  ///
  /// 幂等: 与上次**成功**推送的值相同就直接返回 —— 轮询每 5s 的定时重推因此几乎零成本,
  /// 不会每 5s 重设一次通知按钮。
  /// 失败可观测: 记一条日志(以前是完全静默), 且不记为"已推送", 下一轮轮询会自然重试。
  Future<void> setActionState({
    required bool liked,
    required String modeIcon,
  }) async {
    if (!isAndroid) return;
    if (_sentLiked == liked && _sentModeIcon == modeIcon) return;
    try {
      await _channel.invokeMethod('setActionState', {
        'liked': liked,
        'modeIcon': modeIcon,
      });
      _sentLiked = liked;
      _sentModeIcon = modeIcon;
    } on PlatformException catch (e) {
      // 通知还没建好/服务未起: 不记为已推送 ⇒ 下一轮轮询重试(自愈), 同时留下可观测痕迹
      debugPrint(
        '[NCM-PLAYER] setActionState 失败(${e.code}: ${e.message}), 下次重试',
      );
    } on MissingPluginException catch (e) {
      debugPrint('[NCM-PLAYER] setActionState 通道缺失: $e');
    }
  }

  /// Android 需要应用私有目录(Rust 默认的 ~/.local/share 在手机上不可写)
  Future<String?> dataDir() async {
    if (!isAndroid) return null;
    return _channel.invokeMethod<String>('dataDir');
  }

  /// 开始播放. [durationMs] 是接口给的歌曲时长: 桌面端"边下边播"时
  /// 解码器一开始算不出总时长(文件还在增长), 进度条先用这个值, 否则会一直显示 0.
  /// [artwork] = 当前播放内容的封面 PNG/JPEG 字节(通知/锁屏/车载的封面)。
  /// Media3 自己按 URL 拉图会用默认 UA, 被网易 CDN 回 403(通知上就是空白),
  /// 所以由 Dart 侧([fetchImageBytes])带正确 UA 下好再传过去; 传 null 就沿用上一张。
  Future<PlayerView> play({
    required BigInt trackId,
    required String url,
    required String title,
    required String artist,
    BigInt? durationMs,
    Uint8List? artwork,
  }) async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('play', {
        'trackId': trackId.toInt(),
        'url': preferHttpsStreamUrl(url),
        'title': title,
        'artist': artist,
        'artwork': artwork,
      });
      return _fromMap(map);
    }
    final state = await rust.playTrack(
      trackId: trackId,
      url: url,
      durationMs: durationMs,
    );
    return _fromRust(state);
  }

  Future<PlayerView> state() async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('state');
      return _fromMap(map);
    }
    return _fromRust(await rust.playerState());
  }

  Future<PlayerView> pause() async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('pause');
      return _fromMap(map);
    }
    return _fromRust(await rust.playerPause());
  }

  Future<PlayerView> resume() async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('resume');
      return _fromMap(map);
    }
    return _fromRust(await rust.playerResume());
  }

  Future<PlayerView> stop() async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('stop');
      return _fromMap(map);
    }
    return _fromRust(await rust.playerStop());
  }

  Future<PlayerView> seek(BigInt positionMs) async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('seek', {
        'positionMs': positionMs.toInt(),
      });
      return _fromMap(map);
    }
    return _fromRust(await rust.playerSeek(positionMs: positionMs));
  }

  /// S3: 把播放调音参数(R2/R5/R7)应用到 Android 的 Media3 播放器。
  /// 非 Android 平台直接返回 null(不抛错, Linux 由 Rust 侧处理)。
  /// [gainDb] 已由调用方把「精细音量 + 响度增益」合成好, 这里原样透传。
  /// [gainSlewDbPerSec] = 增益变化的限速(dB/s): 0 = 瞬时(静态 RG2.0); 3.0 = 动态 AGC 防 pump。
  Future<Map<String, Object?>?> applyTuning({
    required double gainDb,
    required int fadeMs,
    required bool hardwareDecode,
    required bool streamCache,
    required int cacheLimitMb,
    String? eqText,
    double gainSlewDbPerSec = 0.0,
  }) async {
    if (!isAndroid) return null;
    return _channel.invokeMapMethod<String, Object?>('configure', {
      'gainDb': gainDb,
      'fadeMs': fadeMs,
      'hardwareDecode': hardwareDecode,
      'streamCache': streamCache,
      'cacheLimitMb': cacheLimitMb,
      'eqText': eqText,
      'gainSlewDbPerSec': gainSlewDbPerSec,
    });
  }

  /// Android: 当前直链在 Media3 SimpleCache 里的完整缓存文件路径(未缓存/未就绪返回 null)。
  ///
  /// 响度均衡(R2b)在手机上要测的就是这个文件 —— 音频由 Media3 缓存, Rust 的 AudioCache 看不到。
  Future<String?> cachedAudioFile(String url) async {
    if (!isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('cachedAudioFile', {
        'url': url,
      });
    } catch (_) {
      return null;
    }
  }

  Future<PlayerView> setVolume(double volume) async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('volume', {
        'volume': volume,
      });
      return _fromMap(map);
    }
    return _fromRust(await rust.playerSetVolume(volume: volume));
  }

  PlayerView _fromRust(rust.PlayerStateDto s) => PlayerView(
    trackId: s.trackId,
    playing: s.playing,
    positionMs: s.positionMs,
    durationMs: s.durationMs,
    volume: s.volume,
  );

  PlayerView _fromMap(Map<String, Object?>? map) {
    if (map == null) return PlayerView.empty;
    BigInt toBig(Object? v) => v is BigInt ? v : BigInt.from((v as num?) ?? 0);
    return PlayerView(
      trackId: map['trackId'] == null ? null : toBig(map['trackId']),
      playing: map['playing'] as bool? ?? false,
      positionMs: toBig(map['positionMs']),
      durationMs: toBig(map['durationMs']),
      volume: (map['volume'] as num?)?.toDouble() ?? 1.0,
    );
  }
}
