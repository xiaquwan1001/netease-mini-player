import 'dart:io';

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

  bool get isAndroid => Platform.isAndroid;

  /// 通知栏/耳机键/蓝牙的上一首·下一首回调.
  /// 原生侧(ForwardingPlayer)只发意图, 真正的换曲在 Dart 队列里做 —— 队列只有一份.
  static void setSkipHandlers({
    void Function()? onNext,
    void Function()? onPrevious,
  }) {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'skipNext':
          onNext?.call();
        case 'skipPrevious':
          onPrevious?.call();
      }
      return null;
    });
  }

  /// Android 需要应用私有目录(Rust 默认的 ~/.local/share 在手机上不可写)
  Future<String?> dataDir() async {
    if (!isAndroid) return null;
    return _channel.invokeMethod<String>('dataDir');
  }

  Future<PlayerView> play({
    required BigInt trackId,
    required String url,
    required String title,
    required String artist,
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
    final state = await rust.playTrack(trackId: trackId, url: url);
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
      final map = await _channel.invokeMapMethod<String, Object?>(
        'seek',
        {'positionMs': positionMs.toInt()},
      );
      return _fromMap(map);
    }
    return _fromRust(await rust.playerSeek(positionMs: positionMs));
  }

  Future<PlayerView> setVolume(double volume) async {
    if (isAndroid) {
      final map = await _channel.invokeMapMethod<String, Object?>(
        'volume',
        {'volume': volume},
      );
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
