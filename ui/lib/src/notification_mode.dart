/// 通知栏「播放顺序」轮转与模式图标名的纯函数。
///
/// 从 `main.dart` 原样搬出, 行为不变; 图标名与 Kotlin 侧 `modeIconRes` 对齐,
/// 单测(test/notification_actions_test.dart)据此校验。
library;

import 'queue.dart';

/// 通知栏「播放顺序」按钮的轮转顺序(列表循环→单曲循环→顺序播放→随机播放→心动模式).
/// 心动模式不是 PlayMode, 用返回 null 表示「下一步应进入心动模式」. 纯函数, 便于单测.
PlayMode? nextNotificationMode(PlayMode mode) {
  const order = [
    PlayMode.repeatAll,
    PlayMode.repeatOne,
    PlayMode.sequence,
    PlayMode.shuffle,
  ];
  final i = order.indexOf(mode);
  return i + 1 < order.length ? order[i + 1] : null;
}

/// 通知栏模式按钮的图标名(与 Kotlin 侧 modeIconRes 对齐); 心动模式优先用 heart 表达.
String notificationModeIcon(PlayMode mode, {required bool heartActive}) {
  if (heartActive) return 'heart';
  return switch (mode) {
    PlayMode.repeatAll => 'repeat',
    PlayMode.repeatOne => 'repeatOne',
    PlayMode.sequence => 'sequence',
    PlayMode.shuffle => 'shuffle',
  };
}
