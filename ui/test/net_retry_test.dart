import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/net_retry.dart';

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
      retryNetwork<int>(() async {
        calls += 1;
        throw Exception('[network] os error 104');
      }, attempts: 3, sleep: (_) async {}),
      throwsA(isA<Exception>()),
    );
    expect(calls, 3);
  });

  test('错误文案: 网络错误说人话, 其它保留原文', () {
    expect(friendlyError('[network] x'), contains('网络不稳定'));
    expect(isNetworkError('[riskControl] code=8821'), isFalse);
    expect(friendlyError('[notFound] code=404'), contains('404'));
  });
}
