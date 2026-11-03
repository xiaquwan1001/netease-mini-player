import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/queue.dart';

void main() {
  group('PlayQueue 手动跳转', () {
    test('setAll 定位与 current', () {
      final q = PlayQueue<String>();
      expect(q.current, isNull);
      q.setAll(['a', 'b', 'c'], startAt: 1);
      expect(q.current, 'b');
      expect(q.items.length, 3);
    });

    test('下一首到队尾后循环回队首', () {
      final q = PlayQueue<String>()..setAll(['a', 'b', 'c'], startAt: 2);
      expect(q.next(), 'a');
      expect(q.next(), 'b');
    });

    test('上一首在队首回到队尾', () {
      final q = PlayQueue<String>()..setAll(['a', 'b', 'c'], startAt: 0);
      expect(q.previous(), 'c');
      expect(q.previous(), 'b');
    });

    test('空队列 next/previous 返回 null', () {
      final q = PlayQueue<String>();
      expect(q.next(), isNull);
      expect(q.previous(), isNull);
      expect(q.onEnded(), isNull);
    });

    test('jumpTo 越界返回 null 且不改变当前', () {
      final q = PlayQueue<String>()..setAll(['a', 'b'], startAt: 0);
      expect(q.jumpTo(5), isNull);
      expect(q.current, 'a');
      expect(q.jumpTo(1), 'b');
    });
  });

  group('PlayQueue 自动续播', () {
    test('列表循环: 队尾之后回到队首', () {
      final q = PlayQueue<String>(mode: PlayMode.repeatAll)
        ..setAll(['a', 'b'], startAt: 1);
      expect(q.onEnded(), 'a');
      expect(q.onEnded(), 'b');
    });

    test('顺序播放: 队尾之后停止', () {
      final q = PlayQueue<String>(mode: PlayMode.sequence)
        ..setAll(['a', 'b'], startAt: 0);
      expect(q.onEnded(), 'b');
      expect(q.onEnded(), isNull);
      expect(q.current, 'b');
    });

    test('单曲循环: 原地重播, 下标不变', () {
      final q = PlayQueue<String>(mode: PlayMode.repeatOne)
        ..setAll(['a', 'b'], startAt: 0);
      expect(q.onEnded(), 'a');
      expect(q.index, 0);
      // 单曲循环下手动下一首仍然有效
      expect(q.next(), 'b');
    });

    test('切模式即时生效', () {
      final q = PlayQueue<String>(mode: PlayMode.repeatAll)
        ..setAll(['a', 'b'], startAt: 1);
      q.mode = PlayMode.sequence;
      expect(q.onEnded(), isNull);
    });
  });
}
