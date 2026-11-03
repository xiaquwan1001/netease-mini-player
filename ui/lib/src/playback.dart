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

/// 播放门面: Android 走 Media3(Kotlin), 其它平台走 Rust core.
/// 规则: 平台差异只允许出现在这一层, UI 不感知.
class Playback {
  static const _channel = MethodChannel('ncm/player');

  bool get isAndroid => Platform.isAndroid;

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
        'url': url,
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
