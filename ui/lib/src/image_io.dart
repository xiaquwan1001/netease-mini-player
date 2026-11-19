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

/// 是否走 Android 的 MediaStore 通道(而不是桌面直接写文件)。
///
/// 判据用框架的 [defaultTargetPlatform] 而不是 `Platform.isAndroid`:
/// 两者在真机上等价, 但前者可以在测试里用 `debugDefaultTargetPlatformOverride`
/// 强制成 android —— 这是"默认保存实现"回归测试(不注入保存实现 + mock
/// `ncm/share` 通道)能真正跑到生产分支的唯一入口; 否则 Linux 上跑 flutter test
/// 永远走桌面分支(会写真磁盘)。
bool get _isAndroid =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
