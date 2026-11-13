import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 把图片字节保存到系统图库/图片目录, 返回保存位置(给用户看的文案用).
///
/// - Android: 走自建 `ncm/share` 通道的 `saveImage`(Kotlin 侧 MediaStore, 落到 Pictures/MiniNCM)
/// - 桌面: Linux `~/Pictures/MiniNCM`, Windows `%USERPROFILE%\\Pictures\\MiniNCM`
///
/// 单独成文件是**为了避免循环依赖**: `cover_art.dart`(看大图要保存)不能 import
/// `song_share.dart`(后者 import 了 cover_art).
const MethodChannel _shareChannel = MethodChannel('ncm/share');

bool get _isAndroid => !kIsWeb && Platform.isAndroid;

Future<String> saveImageBytes(
  Uint8List bytes, {
  required String filename,
}) async {
  if (_isAndroid) {
    final saved = await _shareChannel.invokeMethod<String>('saveImage', {
      'bytes': bytes,
      'filename': filename,
    });
    return saved ?? '系统图库';
  }
  final env = Platform.environment;
  final home = Platform.isWindows
      ? (env['USERPROFILE'] ?? '.')
      : (env['HOME'] ?? '.');
  final dir = Directory(
    Platform.isWindows ? '$home\\Pictures\\MiniNCM' : '$home/Pictures/MiniNCM',
  );
  await dir.create(recursive: true);
  final path = '${dir.path}/$filename';
  await File(path).writeAsBytes(bytes, flush: true);
  return path;
}
