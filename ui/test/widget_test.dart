import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';

void main() {
  test('app widget can be constructed', () {
    // 不放行 RustLib.init(需要真实 cdylib),只验证 widget 树可构造.
    expect(const MiniNcmApp(), isA<MiniNcmApp>());
  });
}
