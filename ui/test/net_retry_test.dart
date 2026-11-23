import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/net_retry.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

void main() {
  test('网络错误会重试, 第二次成功', () async {
    var calls = 0;
    final v = await retryNetwork(() async {
      calls += 1;
      if (calls < 2) throw Exception('[network] error sending request');
      return 42;
    }, sleep: (_) async {});
    expect(v, 42);
    expect(calls, 2);
  });

  test('非网络错误不重试, 立刻抛出', () async {
    var calls = 0;
    await expectLater(
      retryNetwork<int>(() async {
        calls += 1;
        throw Exception('[auth] 未登录不能收藏');
      }, sleep: (_) async {}),
      throwsA(isA<Exception>()),
    );
    expect(calls, 1);
  });

  test('一直失败时按次数上限放弃', () async {
    var calls = 0;
    await expectLater(
      retryNetwork<int>(
        () async {
          calls += 1;
          throw Exception('[network] os error 104');
        },
        attempts: 3,
        sleep: (_) async {},
      ),
      throwsA(isA<Exception>()),
    );
    expect(calls, 3);
  });

  test('错误文案: 网络错误说人话, 其它保留原文', () {
    expect(friendlyError('[network] x'), contains('网络不稳定'));
    expect(isNetworkError('[riskControl] code=8821'), isFalse);
    expect(friendlyError('[notFound] code=404'), contains('404'));
  });

  group('结构化错误(FfiError 跨桥后)', () {
    rust.FfiError fe(String kind, String detail, {bool retryable = false}) =>
        rust.FfiError(kind: kind, retryable: retryable, detail: detail);

    test('kind/retryable 直接来自 Rust, 不再靠文本前缀', () {
      final net = fe('network', 'os error 104', retryable: true);
      expect(isNetworkError(net), isTrue);
      expect(isRetryableError(net), isTrue);
      expect(friendlyError(net), contains('网络不稳定'));

      final auth = fe('auth', '未登录');
      expect(isNetworkError(auth), isFalse);
      expect(isRetryableError(auth), isFalse);
      // auth: detail 是后端内部文本, 不抛给用户(2026-11-18 用户反馈)
      expect(friendlyError(auth), '需要登录后才能查看');
      expect(errorKind(auth), 'auth');
      expect(describeError(auth), '[auth] 未登录');
    });

    test('forbidden 只给 detail, 空 detail 兜底', () {
      expect(friendlyError(fe('forbidden', '该用户已设置关注列表不可见')), '该用户已设置关注列表不可见');
      expect(friendlyError(fe('forbidden', '')), '没有权限查看');
    });

    test('riskControl 给出「换网络/登录」两条出路, 并保留上游原文', () {
      // 2026-11-23: 网易云 -462 人机验证。以前这里落进兜底分支, 界面上直接是
      // "[riskControl] code=-462: 请完成验证操作"(用户读不懂, 以为是客户端坏了)。
      final rc = fe('riskControl', 'code=-462: 请完成验证操作');
      expect(isNetworkError(rc), isFalse);
      // 风控不是网络抖动, 不许被 retryNetwork 自动重试(那只会加重风控)
      expect(isRetryableError(rc), isFalse);
      final text = friendlyError(rc);
      expect(text, contains('风控'));
      expect(text, contains('换网络'));
      expect(text, contains('登录'));
      expect(text, contains('请完成验证操作'), reason: '上游原文要留住, 便于判断具体原因');
      expect(text, isNot(contains('[riskControl]')), reason: '不能把内部 kind 露给用户');
      // 文本前缀路径(老异常)也走同一套话术
      expect(friendlyError('[riskControl] code=-462'), contains('风控'));
    });

    test('network 的 FfiError 会被 retryNetwork 重试', () async {
      var calls = 0;
      final v = await retryNetwork(() async {
        calls += 1;
        if (calls < 3) {
          throw fe('network', 'connection reset', retryable: true);
        }
        return 7;
      }, sleep: (_) async {});
      expect(v, 7);
      expect(calls, 3);
    });

    test('retryable=false 的 FfiError 不重试', () async {
      var calls = 0;
      await expectLater(
        retryNetwork<int>(() async {
          calls += 1;
          throw fe('internal', 'boom');
        }, sleep: (_) async {}),
        throwsA(isA<rust.FfiError>()),
      );
      expect(calls, 1);
    });
  });
}
