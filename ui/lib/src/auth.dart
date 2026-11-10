import 'dart:io';

import 'package:flutter/services.dart';

import 'rust/api.dart' as rust;

/// 登录门面: 平台差异只出现在这一层。
///
/// Android = 内嵌官方网页授权页(WebView) → 取 MUSIC_U cookie → 交 Rust 落盘;
/// 桌面端(Linux/Windows) = 官方网页登录的**扫码通道**
/// (rust.loginQrCreate / loginQrCheck, 见 login_sheet.dart): 不用 WebView,
/// 也不必让用户去命令行粘贴 cookie —— MUSIC_U 是 HttpOnly, 系统浏览器里读不到.
///
/// 为什么不用原生登录接口(手机号/密码/验证码): 会返 8821 安全环境风险(见项目记忆),
/// 官方网页登录是已知的零风控路径; 桌面端的扫码正是**网页登录**那套通道
/// (/api/login/qrcode/unikey + client/login, weapi), 不是 App 原生登录族。
/// `ncm login-qr` 是同一实现的 headless 版本, 排障时可直接用。
class Auth {
  static const _channel = MethodChannel('ncm/auth');

  bool get isAndroid => Platform.isAndroid;

  /// 打开官方移动端授权页(手机号/微信/QQ/扫码都在页内)。
  /// 返回 null 表示用户放弃, 或页面自始至终没拿到登录态。
  Future<String?> loginWeb() async {
    if (!isAndroid) {
      throw UnsupportedError('桌面端走扫码登录(loginQrCreate), 不用 WebView');
    }
    return _channel.invokeMethod<String>('loginWeb');
  }

  /// 把网页登录拿到的 cookie 与设备指纹合并后落盘(device_id 永久复用)
  Future<bool> commitCookie(String cookie) => rust.loginWithCookie(cookie: cookie);

  /// 退出登录(换账号用): 清 Rust 侧登录凭据 + 清 WebView cookie,
  /// 但**保留设备指纹**(deviceId/_ntes_nuid/WNMCID/NMTID 不变 = 还是同一台设备)。
  Future<bool> logout() async {
    if (isAndroid) {
      try {
        await _channel.invokeMethod<bool>('clearCookies');
      } catch (_) {
        // 清不干净也不阻塞退出, 下次打开登录页最多是旧账号已登录态
      }
    }
    return rust.logout();
  }
}
