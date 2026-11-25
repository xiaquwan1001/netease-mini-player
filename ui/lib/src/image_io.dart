import 'dart:io';

import 'package:flutter/services.dart';

import 'platform_is.dart' show usesDefaultTargetPlatformAndroid;

/// 把图片字节保存到系统图库/图片目录, 返回保存位置(给用户看的文案用).
///
/// - Android: 走自建 `ncm/share` 通道的 `saveImage`(Kotlin 侧 MediaStore, 落到 Pictures/MiniNCM)
/// - 桌面: Linux `~/Pictures/MiniNCM`, Windows `%USERPROFILE%\\Pictures\\MiniNCM`
///
/// 单独成文件是**为了避免循环依赖**: `cover_art.dart`(看大图要保存)不能 import
/// `song_share.dart`(后者 import 了 cover_art).
const MethodChannel _shareChannel = MethodChannel('ncm/share');

/// 是否走 Android 的 MediaStore 通道(而不是桌面直接写文件)。

Future<String> saveImageBytes(
  Uint8List bytes, {
  required String filename,
}) async {
  // 判据是 `platform_is.dart` 的 [usesDefaultTargetPlatformAndroid]: 那里刻意用框架的
  // `defaultTargetPlatform`, 好让「默认保存实现」回归测试用 `debugDefaultTargetPlatformOverride`
  // 跑到生产分支(见 test/detail_faces_test.dart)。
  if (usesDefaultTargetPlatformAndroid) {
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
