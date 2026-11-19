import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/queue.dart';

void main() {
  group('通知栏播放顺序轮转(nextNotificationMode)', () {
    test('只有 4 档: 列表循环→单曲循环→顺序播放→随机播放→回到列表循环', () {
      expect(nextNotificationMode(PlayMode.repeatAll), PlayMode.repeatOne);
      expect(nextNotificationMode(PlayMode.repeatOne), PlayMode.sequence);
      expect(nextNotificationMode(PlayMode.sequence), PlayMode.shuffle);
      expect(nextNotificationMode(PlayMode.shuffle), PlayMode.repeatAll);
    });

    test('轮转永不返回 null(心动模式/私人FM 已从轮转里独立出去)', () {
      for (final mode in PlayMode.values) {
        expect(nextNotificationMode(mode), isNotNull);
      }
    });

    test('轮一圈回到起点, 且不经过引导态', () {
      var mode = PlayMode.repeatAll;
      final seen = <PlayMode>[];
      for (var i = 0; i < 4; i++) {
        mode = nextNotificationMode(mode);
        seen.add(mode);
      }
      expect(seen, [
        PlayMode.repeatOne,
        PlayMode.sequence,
        PlayMode.shuffle,
        PlayMode.repeatAll,
      ]);
    });
  });

  group('通知栏模式图标(notificationModeIcon)', () {
    test('私人FM 优先用 fm', () {
      expect(notificationModeIcon(PlayMode.repeatAll, fmActive: true), 'fm');
      // 同时在心动/FM 时 FM 优先(不会同时进两个引导态, 但优先级要确定)
      expect(
        notificationModeIcon(
          PlayMode.shuffle,
          heartActive: true,
          fmActive: true,
        ),
        'fm',
      );
    });

    test('心动模式用 heart(与 Kotlin ic_notif_heart_fire 对齐, 不再复用红心)', () {
      expect(
        notificationModeIcon(PlayMode.repeatAll, heartActive: true),
        'heart',
      );
    });

    test('四种 PlayMode 的映射与 Kotlin modeIconRes 对齐', () {
      expect(notificationModeIcon(PlayMode.repeatAll), 'repeat');
      expect(notificationModeIcon(PlayMode.repeatOne), 'repeatOne');
      expect(notificationModeIcon(PlayMode.sequence), 'sequence');
      expect(notificationModeIcon(PlayMode.shuffle), 'shuffle');
    });
  });
}
