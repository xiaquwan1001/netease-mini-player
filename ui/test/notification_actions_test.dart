import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/queue.dart';

void main() {
  group('通知栏播放顺序轮转(nextNotificationMode)', () {
    test('列表循环→单曲循环→顺序播放→随机播放', () {
      expect(nextNotificationMode(PlayMode.repeatAll), PlayMode.repeatOne);
      expect(nextNotificationMode(PlayMode.repeatOne), PlayMode.sequence);
      expect(nextNotificationMode(PlayMode.sequence), PlayMode.shuffle);
    });
    test('随机播放之后进入心动模式(返回 null)', () {
      expect(nextNotificationMode(PlayMode.shuffle), isNull);
    });
  });

  group('通知栏模式图标(notificationModeIcon)', () {
    test('心动模式优先用 heart', () {
      expect(
        notificationModeIcon(PlayMode.repeatAll, heartActive: true),
        'heart',
      );
    });
    test('四种 PlayMode 的映射与 Kotlin modeIconRes 对齐', () {
      expect(notificationModeIcon(PlayMode.repeatAll, heartActive: false), 'repeat');
      expect(notificationModeIcon(PlayMode.repeatOne, heartActive: false), 'repeatOne');
      expect(notificationModeIcon(PlayMode.sequence, heartActive: false), 'sequence');
      expect(notificationModeIcon(PlayMode.shuffle, heartActive: false), 'shuffle');
    });
  });
}
