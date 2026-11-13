import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

  // 原生 → Dart 的单向回调(通知栏/耳机键/蓝牙都只发意图, 逻辑在 Dart):
  // 两条注册入口共用一个 handler, 后注册的不会把先注册的覆盖掉.
  static void Function()? _onNext;
  static void Function()? _onPrevious;
  static void Function()? _onToggleLike;
  static void Function()? _onCycleMode;

  /// 通知栏/耳机键/蓝牙的上一首·下一首回调.
  /// 原生侧(ForwardingPlayer)只发意图, 真正的换曲在 Dart 队列里做 —— 队列只有一份.
  static void setSkipHandlers({
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    _onNext = onNext;
    _onPrevious = onPrevious;
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

  static void _registerNativeHandler() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'skipNext':
          _onNext?.call();
        case 'skipPrevious':
          _onPrevious?.call();
        case 'toggleLike':
          _onToggleLike?.call();
        case 'cycleMode':
          _onCycleMode?.call();
      }
      return null;
    });
  }

  /// Dart → 原生: 通知自定义按钮的状态(红心实/空 + 模式图标), 原生据此重设按钮并刷新通知.
  /// 失败静默(通知未就绪/未连接时不影响播放).
  Future<void> setActionState({
    required bool liked,
    required String modeIcon,
  }) async {
    if (!isAndroid) return;
    try {
      await _channel.invokeMethod('setActionState', {
        'liked': liked,
        'modeIcon': modeIcon,
      });
    } on PlatformException {
      // 通知还没建好/服务未起: 忽略, 下次状态变化再同步
    }
  }

  /// Android 需要应用私有目录(Rust 默认的 ~/.local/share 在手机上不可写)
  Future<String?> dataDir() async {
    if (!isAndroid) return null;
    return _channel.invokeMethod<String>('dataDir');
  }

  /// 开始播放. [durationMs] 是接口给的歌曲时长: 桌面端"边下边播"时
  /// 解码器一开始算不出总时长(文件还在增长), 进度条先用这个值, 否则会一直显示 0.
  Future<PlayerView> play({
    required BigInt trackId,
    required String url,
    required String title,
    required String artist,
    BigInt? durationMs,
  }) async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>('play', {
        'trackId': trackId.toInt(),
        'url': preferHttpsStreamUrl(url),
        'title': title,
        'artist': artist,
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
