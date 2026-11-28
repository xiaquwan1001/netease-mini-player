import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/lru.dart';

void main() {
  group('LruMap', () {
    test('写入后在 keys 里按最久未用 -> 最新排列', () {
      final lru = LruMap<String, int>(maxEntries: 3);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('c', 3);
      expect(lru.keys.toList(), <String>['a', 'b', 'c']);
      expect(lru.length, 3);
    });

    test('超上限淘汰最久未用的那一条', () {
      final lru = LruMap<String, int>(maxEntries: 2);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('c', 3);
      expect(lru.length, 2);
      expect(lru.containsKey('a'), isFalse);
      expect(lru.keys.toList(), <String>['b', 'c']);
    });

    test('读取即触碰: 命中过的条目不再是淘汰目标', () {
      final lru = LruMap<String, int>(maxEntries: 2);
      lru.put('a', 1);
      lru.put('b', 2);
      expect(lru['a'], 1); // 触碰 a
      lru.put('c', 3); // 此时最久未用的是 b
      expect(lru.containsKey('b'), isFalse);
      expect(lru.containsKey('a'), isTrue);
      expect(lru.keys.toList(), <String>['a', 'c']);
    });

    test('未命中返回 null 且不改动淘汰顺序', () {
      final lru = LruMap<String, int>(maxEntries: 2);
      lru.put('a', 1);
      expect(lru['zzz'], isNull);
      expect(lru.keys.toList(), <String>['a']);
    });

    test('peek 只读不触碰', () {
      final lru = LruMap<String, int>(maxEntries: 2);
      lru.put('a', 1);
      lru.put('b', 2);
      expect(lru.peek('a'), 1);
      lru.put('c', 3); // peek 不算使用, 淘汰 a
      expect(lru.containsKey('a'), isFalse);
    });

    test('覆盖写视为最新, 只保留一份', () {
      final lru = LruMap<String, int>(maxEntries: 2);
      lru.put('a', 1);
      lru.put('b', 2);
      lru.put('a', 9);
      expect(lru.length, 2);
      expect(lru['a'], 9);
      expect(lru.keys.toList(), <String>['b', 'a']);
      lru.put('c', 3); // 最久未用是 b
      expect(lru.keys.toList(), <String>['a', 'c']);
    });

    test('remove / clear', () {
      final lru = LruMap<String, int>(maxEntries: 4);
      lru.put('a', 1);
      lru.put('b', 2);
      expect(lru.remove('a'), 1);
      expect(lru.remove('a'), isNull);
      expect(lru.keys.toList(), <String>['b']);
      lru.clear();
      expect(lru.isEmpty, isTrue);
      expect(lru.keys, isEmpty);
    });

    test('不设上限时不淘汰', () {
      final lru = LruMap<int, String>();
      for (var i = 0; i < 50; i++) {
        lru.put(i, 'v$i');
      }
      expect(lru.length, 50);
      expect(lru[0], 'v0');
    });

    test('值可以是任意非空对象(如 Future)', () async {
      final lru = LruMap<String, Future<int>>(maxEntries: 1);
      lru.put('a', Future<int>.value(7));
      lru.put('b', Future<int>.value(8));
      expect(lru.containsKey('a'), isFalse);
      expect(await lru['b'], 8);
    });

    test('maxEntries 必须是正数', () {
      expect(
        () => LruMap<String, int>(maxEntries: 0),
        throwsA(isA<AssertionError>()),
      );
    });

    test('字节超限淘汰(条目数没超也要淘汰): 单条比上限大时至少留一条', () {
      // 图片字节缓存就靠这条: 200 条里混着 20KB 缩略图与 1MB 原图(2026-11-28 审计 P1-2)
      final lru = LruMap<String, List<int>>(
        maxEntries: 200,
        maxBytes: 100,
        sizeOf: (v) => v.length,
      );
      lru.put('a', List<int>.filled(40, 0));
      lru.put('b', List<int>.filled(40, 0));
      expect(lru.length, 2);
      expect(lru.bytes, 80);

      lru.put('c', List<int>.filled(40, 0)); // 120 > 100 ⇒ 淘汰最久未用的 a
      expect(lru.keys.toList(), <String>['b', 'c']);
      expect(lru.bytes, 80);

      // 覆盖写: 旧的字节要先扣掉(否则会越算越大)
      lru.put('c', List<int>.filled(10, 0));
      expect(lru.bytes, 50);

      // 单条就超上限: 仍保留这一条(缓存不该形同关闭)
      lru.put('huge', List<int>.filled(1000, 0));
      expect(lru.containsKey('huge'), isTrue);
      expect(lru.length, 1);

      lru.remove('huge');
      expect(lru.bytes, 0);
    });
  });
}
