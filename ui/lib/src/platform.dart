import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 平台能力桥: 打开外部链接 / 下载到系统下载目录.
/// Android 走 `ncm/open` 通道(DownloadManager 免存储权限);
/// Linux 用系统 xdg-open / curl 落到 ~/Downloads.
class PlatformBridge {
  static const MethodChannel _channel = MethodChannel('ncm/open');

  static bool get _android => !kIsWeb && Platform.isAndroid;

  /// 用系统浏览器/播放器打开链接(动态里的视频等)
  static Future<void> openUrl(String url) async {
    if (url.isEmpty) return;
    if (_android) {
      await _channel.invokeMethod<void>('openUrl', {'url': url});
      return;
    }
    if (kIsWeb) return;
    await Process.run('xdg-open', [url]);
  }

  /// 下载文件. 返回保存位置(Android 返回下载任务 id 的说明文案在调用方拼).
  static Future<String?> download({
    required String url,
    required String filename,
    String? userAgent,
  }) async {
    if (url.isEmpty) return null;
    final safe = filename.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');
    if (_android) {
      return _channel.invokeMethod<String>('download', {
        'url': url,
        'filename': safe,
        'ua': userAgent,
      });
    }
    if (kIsWeb) return null;
    final home = Platform.environment['HOME'] ?? '.';
    final dir = Directory('$home/Downloads');
    await dir.create(recursive: true);
    final path = '${dir.path}/$safe';
    final args = <String>['-L', '--fail', '--silent', '--show-error', '-o', path];
    if (userAgent != null && userAgent.isNotEmpty) {
      args.addAll(['-A', userAgent]);
    }
    args.add(url);
    final result = await Process.run('curl', args);
    if (result.exitCode != 0) {
      throw Exception('下载失败: ${result.stderr}');
    }
    return path;
  }
}
