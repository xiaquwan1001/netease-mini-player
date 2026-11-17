import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/net_retry.dart';

void main() {
  group('friendlyError', () {
    test('forbidden 去掉内部 kind 前缀, 直接给隐私文案', () {
      final e = Exception('[forbidden] 该用户已设置关注列表不可见');
      expect(friendlyError(e), '该用户已设置关注列表不可见');
    });

    test('forbidden 无 detail 时给兜底文案', () {
      expect(friendlyError(Exception('[forbidden]')), '没有权限查看');
    });

    test('network 仍是统一的网络文案', () {
      expect(
        friendlyError(Exception('[network] error sending request')),
        contains('网络不稳定'),
      );
    });

    test('auth 换成中性引导, 不泄露后端内部 detail', () {
      // 后端原样抛出的是 `[auth] Unknown error`(detail 对用户零信息量)
      expect(friendlyError(Exception('[auth] Unknown error')), '需要登录后才能查看');
      expect(friendlyError(Exception('[auth]')), '需要登录后才能查看');
    });

    test('其它 kind 原样返回(方便定位)', () {
      final e = Exception('[internal] code=500');
      expect(friendlyError(e), contains('[internal]'));
    });
  });
}
