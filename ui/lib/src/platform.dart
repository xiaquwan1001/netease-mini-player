import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_is.dart' show isAndroidPlatform;

/// 网易云 CDN 要求的 Referer。缺了它直链会 403, 图片与音频一样。
///
/// 同一个值目前有**四处**, 没有编译期共享的办法(Dart 常量 / Kotlin 字面量 / Rust 常量),
/// 改一处就要手工核对另外三处:
/// - Dart 侧(本常量): 桌面 curl 下载(`desktopCurlDownloadArgs`);
/// - Dart 侧(字面量副本): `cover_art.dart` 的 `_UaNetworkImage._download`;
/// - Android: `MainActivity.kt` 的 `ncm/open.download` 请求头与
///   `PlaybackService.kt` 里 `DefaultHttpDataSource` 的默认请求头(都是这个值);
/// - Rust: `core/crates/ncm-service/src/cache.rs` 的 `DOWNLOAD_REFERER`。
const String kMusic163Referer = 'https://music.163.com/';

/// 平台能力桥: 打开外部链接 / 下载到系统下载目录.
/// Android 走 `ncm/open` 通道(DownloadManager 免存储权限);
/// Linux 用系统 xdg-open / curl 落到 ~/Downloads;
/// Windows 用 `rundll32 url.dll,FileProtocolHandler` 打开链接、curl 落到 %USERPROFILE%\Downloads.
class PlatformBridge {
  static const MethodChannel _channel = MethodChannel('ncm/open');

  static bool get _windows => !kIsWeb && Platform.isWindows;

  /// 当前系统的下载目录(桌面端用; Android 走 DownloadManager 不经过这里)
  static String _downloadDir() {
    final env = Platform.environment;
    if (_windows) {
      final profile = env['USERPROFILE'] ?? env['USERPROFILE'.toLowerCase()];
      if (profile != null && profile.isNotEmpty) return '$profile\\Downloads';
    }
    final home = env['HOME'] ?? '.';
    return '$home/Downloads';
  }

  /// 用系统浏览器/播放器打开链接(动态里的视频等)
  static Future<void> openUrl(String url) async {
    if (url.isEmpty) return;
    if (isAndroidPlatform) {
      await _channel.invokeMethod<void>('openUrl', {'url': url});
      return;
    }
    if (kIsWeb) return;
    if (_windows) {
      // rundll32 是 Windows 上最稳的"用默认程序打开 URL"方式(不需要 start cmd)
      await Process.run('rundll32', ['url.dll,FileProtocolHandler', url]);
      return;
    }
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
    if (isAndroidPlatform) {
      return _channel.invokeMethod<String>('download', {
        'url': url,
        'filename': safe,
        'ua': userAgent,
      });
    }
    if (kIsWeb) return null;
    final dir = Directory(_downloadDir());
    await dir.create(recursive: true);
    final path = '${dir.path}/$safe';
    final result = await Process.run(
      'curl',
      desktopCurlDownloadArgs(url: url, path: path, userAgent: userAgent),
    );
    if (result.exitCode != 0) {
      throw Exception('下载失败: ${result.stderr}');
    }
    return path;
  }
}

/// 桌面 curl 下载的参数(纯函数, 单测锁请求头口径).
///
/// 请求头必须与安卓 / Rust 侧一致(D12):
/// - `Referer: https://music.163.com/` —— CDN 不带它直接 403, 而以前桌面这条路
///   只有 `-L --fail`, 于是"Rust 边下边播能成、点下载 403";
/// - UA 有则带上(`-A`): 网易 CDN 对 `Dart/3.x` 这类默认 UA 也回 403。
@visibleForTesting
List<String> desktopCurlDownloadArgs({
  required String url,
  required String path,
  String? userAgent,
}) => [
  '-L',
  '--fail',
  '--silent',
  '--show-error',
  '-H',
  'Referer: $kMusic163Referer',
  '-o',
  path,
  if (userAgent != null && userAgent.isNotEmpty) ...['-A', userAgent],
  url,
];
