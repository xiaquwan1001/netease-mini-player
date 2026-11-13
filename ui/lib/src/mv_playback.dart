import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform.dart';

/// MV 播放通道: Android 走 `ncm/mv` MethodChannel 起独立 VideoView Activity;
/// 其他平台(Linux 桌面)没有内嵌视频能力, 用系统播放器/浏览器打开直链。
class MvPlayback {
  MvPlayback({MethodChannel? channel, this.playOverride})
    : _channel = channel ?? const MethodChannel('ncm/mv');

  final MethodChannel _channel;

  /// 测试注入: 直接接管 play(不触平台通道)
  final Future<void> Function(String url, String title)? playOverride;

  /// Android 是否支持内嵌播放(决定 UI 显示「播放」还是「外链」)
  bool get supportsInlinePlayback => !kIsWeb && Platform.isAndroid;

  /// 播放 MV 直链. [url] 必须是 https 直链(取链后即播, 直链 1 小时过期)。
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
