import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android Keystore 凭据后端的 Dart 封装(通道层).
///
/// 原生侧见 `ui/android/app/src/main/kotlin/**/KeystoreChannel.kt`:
/// AES-256-GCM 密钥(alias `minincm-cred-v1`)加密后落到 `filesDir/cred/<key>.bin`.
/// Rust identity 侧尚未接线, 这里只提供能被上层调用的通道.
///
/// 平台差异: 非 Android 上 `available()` 恒为 false, `put()` 返回 false,
/// 绝不在非 Android 平台偷偷写明文; 上层据此决定回退方案.
class KeystoreChannel {
  KeystoreChannel({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('ncm/keystore');

  final MethodChannel _channel;

  /// 测试专用: host 上 Platform.isAndroid 恒为 false, 置 true 可强制走 Android 分支.
  @visibleForTesting
  static bool debugForceAndroid = false;

  bool get _isAndroid => !kIsWeb && Platform.isAndroid || debugForceAndroid;

  /// Keystore 是否可用(能取到/能创建密钥就 true).
  /// 非 Android 恒为 false; 通道异常按不可用处理.
  Future<bool> available() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 写入凭据 [key] -> [value](原生侧加密落盘).
  /// 返回 false 表示平台不支持或原生失败, 不抛异常, 由上层决定回退.
  Future<bool> put(String key, String value) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'put',
            {'key': key, 'value': value},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 读取凭据; 不存在/密钥失效(清数据、备份恢复)/通道异常一律返回 null.
  Future<String?> get(String key) async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMethod<String>('get', {'key': key});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 删除凭据; 返回是否确实删掉了文件. 通道异常按 false 处理.
  Future<bool> remove(String key) async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('remove', {'key': key}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
