// 登录弹层错误文案: 把桥那边的 `[kind] detail` 换成人话, 但保留动作前缀与服务端原文.
//
// Rust 侧统一 `[auth|riskControl|network|notFound|unsupported|internal] detail`,
// Dart 拿到 `Exception: [kind] ...`; 直接铺给用户会看到方括号和类型名.
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/login_sheet.dart';

void main() {
  test('auth: 去掉 Exception/[auth], 保留动作前缀与服务端原文', () {
    expect(
      friendlyLoginError('发送验证码失败: Exception: [auth] code=400: 手机号码不符合规范'),
      '发送验证码失败: 信息有误: code=400: 手机号码不符合规范',
    );
  });

  test('riskControl: 标签可读, 且原文仍在(便于判断是不是 8821)', () {
    final s = friendlyLoginError(
      'Exception: [riskControl] code=8821: 安全环境风险, 请切换其他登录方式',
    );
    expect(s, contains('被网易云安全风控拦截'));
    expect(s, contains('8821'));
    expect(s, isNot(contains('[riskControl]')));
    expect(s, isNot(contains('Exception:')));
  });

  test('没有 kind 前缀 / 未知 kind 时原样返回', () {
    expect(friendlyLoginError('先填手机号'), '先填手机号');
    expect(friendlyLoginError('扫码失败(code=800)'), '扫码失败(code=800)');
    expect(friendlyLoginError('[whatever] x'), '[whatever] x');
  });

  test('只有 kind 没有 detail 时只给标签', () {
    expect(friendlyLoginError('登录失败: Exception: [network]'), '登录失败: 网络不通');
  });
}
