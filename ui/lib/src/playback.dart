import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';

import 'rust/api_all.dart' as rust;

/// UI 用的播放状态(与 Rust/Android 两侧统一)
class PlayerView {
  const PlayerView({
    this.trackId,
    required this.playing,
    required this.positionMs,
    required this.durationMs,
    required this.volume,
    this.seekable = true,
    this.seekError,
    this.pendingSeekMs,
  });

  final BigInt? trackId;
  final bool playing;
  final BigInt positionMs;
  final BigInt durationMs;
  final double volume;

  /// 当前源能否精确 seek。
  ///
  /// 桌面端「边下边播」期解码器是非 seekable 的(Rust 侧 `with_seekable(false)`)。
  /// P-10 方案 B 之后这种状态**不再意味着不能跳**: seek 会登记成待跳
  /// ([pendingSeekMs]), 缓存完成后换源重建解码器再跳过去。所以这个标志现在只用于
  /// 展示/诊断, 进度条不再据它禁拖。
  /// Android 走 Media3, 通道里没有这个键 ⇒ 默认 true(行为不变)。
  final bool seekable;

  /// 最近一次 seek 失败的原因(Rust 侧 `PlayerState::seek_error` 的直传)。
  /// null = 没失败过 / 上次成功。
  final String? seekError;

  /// 已登记的待跳位置(P-10 方案 B; Rust 侧 `PlayerState::pending_seek_ms` 的直传)。
  /// null = 没有挂起的跳转; 非 null 时 UI 显示「已排队→mm:ss」并把拇指停在这里。
  final BigInt? pendingSeekMs;

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
/// 更糟的是直接换成 **200 + text/html** 的重定向页(桌面实测), 那是静默播不了。
/// CDN 同路径支持 https(证书覆盖 *.music.126.net), 两端统一升级到 https。
///
/// **只升级网易域名族**(与 Rust `ncm_service::cache::prefer_https` 同一口径):
/// 第三方音源将来可能只支持明文, 替人家假设"一定有 https"会把能播的源改坏。
/// 纯函数 + 可注入判定([shouldUpgrade]), 方便单测。
String preferHttpsStreamUrl(
  String url, {
  bool Function(String host)? shouldUpgrade,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'http' || uri.host.isEmpty) return url;
  final allow = shouldUpgrade ?? isNeteaseStreamHost;
  if (!allow(uri.host)) return url;
  // 显式 :80 要一并去掉(https 的默认端口是 443)
  return uri
      .replace(
        scheme: 'https',
        port: uri.hasPort && uri.port != 80 ? uri.port : null,
      )
      .toString();
}

/// 网易域名族(`*.music.126.net` 直链边缘 / `*.music.163.com` 接口域).
bool isNeteaseStreamHost(String host) {
  final h = host.toLowerCase();
  return h == '126.net' ||
      h.endsWith('.126.net') ||
      h == '163.com' ||
      h.endsWith('.163.com');
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
      // 播放 UA 的唯一来源在 Rust: 启动时就把真值推给原生(Kotlin 只留兜底常量, P-21)。
      // 与握手同一条通道, 不额外阻塞启动(失败只留日志, 首次 play 前还会再试一次)。
      unawaited(_injectUserAgent());
      _channel
          .invokeMethod<void>('actionHandlersReady')
          .catchError((Object _) {});
    }
  }

  // ---- 播放 UA 单一来源(P-21): Rust → FFI → Dart → Kotlin ----
  // 以前 Kotlin 的 PlaybackService.USER_AGENT 与 Rust 的 platform_profile().ua 是两份手抄常量,
  // 升级客户端版本只改一侧 ⇒ "取链用新 UA、播放用旧 UA" ⇒ 偶发 403/偶发无声。
  // 现在真值只有一处(Rust), Dart 把它推过去; Kotlin 的常量降级为兜底。

  /// 是否已成功把 UA 交给原生(成功一次就够)
  static bool _uaInjected = false;

  /// 正在进行中的注入(并发调用合并成一次)
  static Future<void>? _uaInjection;

  /// 测试用: 清掉注入缓存(生产路径不需要)
  @visibleForTesting
  static void debugResetUserAgentCache() {
    _uaInjected = false;
    _uaInjection = null;
  }

  /// 把 Rust 的播放 UA 推给原生(只 Android 需要: 桌面端的播放请求由 Rust 自己发)。
  ///
  /// 幂等且可重试: 成功后置位不再重复; 失败(原生服务没起 / Rust 未就绪)只留一条
  /// `NCM-UA` 日志, 下次调用(启动握手之后的首次 [play])会再试。
  static Future<void> _injectUserAgent() {
    if (_uaInjected) return Future<void>.value();
    final pending = _uaInjection;
    if (pending != null) return pending;
    final future = _doInjectUserAgent().whenComplete(() {
      _uaInjection = null;
    });
    _uaInjection = future;
    return future;
  }

  static Future<void> _doInjectUserAgent() async {
    final String ua;
    try {
      // 同步 FFI: 纯常量读取(不进入 async 运行时)
      ua = rust.playbackUserAgent();
    } catch (e) {
      debugPrint('[NCM-UA] 取 Rust 的播放 UA 失败(原生继续用兜底常量): $e');
      return;
    }
    if (ua.trim().isEmpty) {
      debugPrint('[NCM-UA] Rust 返回的播放 UA 为空(原生继续用兜底常量)');
      return;
    }
    try {
      await _channel.invokeMethod<void>('setUserAgent', {'ua': ua});
      _uaInjected = true;
      debugPrint('[NCM-UA] 已把 Rust 的播放 UA 交给原生: $ua');
    } on MissingPluginException catch (e) {
      debugPrint('[NCM-UA] setUserAgent 通道缺失(非 Android 构建?): $e');
    } on PlatformException catch (e) {
      debugPrint('[NCM-UA] setUserAgent 失败(${e.code}: ${e.message}), 下次再试');
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
    // 起播位置(毫秒): 仅在恢复现场的续播时非空。Android 交给
    // `MediaController.setMediaItem(item, ms)`; 桌面 Rust 侧没这个参数, 仍由调用方起播后 seek。
    BigInt? startPositionMs,
  }) async {
    if (isAndroid) {
      // 首播前保证 UA 已交给原生(启动握手时服务可能还没起, 那次失败了就在这里补)
      await _injectUserAgent();
      final map = await _channel.invokeMapMethod<String, Object?>('play', {
        'trackId': trackId.toInt(),
        'url': preferHttpsStreamUrl(url),
        'title': title,
        'artist': artist,
        'artwork': artwork,
        if (startPositionMs != null && startPositionMs > BigInt.zero)
          'positionMs': startPositionMs.toInt(),
      });
      return _fromMap(map);
    }
    // 桌面同样强制 https(T2): 以前这里直接把上游给的明文直链交给 Rust,
    // 明文 80 在校园网/跨境链路上会被中间设备换成 HTML 重定向页(实测)。
    // Rust 的下载器会再兜底升一次, 这里先升是为了日志/缓存键都看到同一个 URL。
    final state = await rust.playTrack(
      trackId: trackId,
      url: preferHttpsStreamUrl(url),
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
    seekable: s.seekable,
    seekError: s.seekError,
    pendingSeekMs: s.pendingSeekMs,
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
      // Android(Media3)通道没有这几个键: 默认可 seek/无待跳, 移动端行为一个字都不变
      seekable: map['seekable'] as bool? ?? true,
      seekError: map['seekError'] as String?,
      pendingSeekMs: map['pendingSeekMs'] == null
          ? null
          : toBig(map['pendingSeekMs']),
    );
  }
}
