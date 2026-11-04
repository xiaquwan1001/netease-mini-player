import 'dart:io';

import 'package:flutter/services.dart';

import 'rust/api.dart' as rust;

/// 登录门面: 平台差异只出现在这一层。
///
/// Android = 内嵌官方网页授权页(WebView) → 取 MUSIC_U cookie → 交 Rust 落盘;
/// Linux = 暂不支持内嵌登录, 用 `ncm login-cookie "MUSIC_U=..."`(或后续的 WebView 方案)。
///
/// 为什么不用原生扫码登录: 用户确认后网易云必返 8821 安全环境风险(见项目记忆),
/// 官方网页登录是已知的零风控路径。
class Auth {
  static const _channel = MethodChannel('ncm/auth');

  bool get isAndroid => Platform.isAndroid;

  /// 打开官方移动端授权页(手机号/微信/QQ/扫码都在页内)。
  /// 返回 null 表示用户放弃, 或页面自始至终没拿到登录态。
  Future<String?> loginWeb() async {
    if (!isAndroid) {
      throw UnsupportedError('Linux 端暂无内嵌登录, 先导入 cookie: ncm login-cookie "MUSIC_U=..."');
    }
    return _channel.invokeMethod<String>('loginWeb');
  }

  /// 把网页登录拿到的 cookie 与设备指纹合并后落盘(device_id 永久复用)
  Future<bool> commitCookie(String cookie) => rust.loginWithCookie(cookie: cookie);
}
