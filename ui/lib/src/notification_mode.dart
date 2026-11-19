/// 通知栏「播放顺序」轮转与模式图标名的纯函数。
///
/// 从 `main.dart` 原样搬出, 图标名与 Kotlin 侧 `modeIconRes` 对齐,
/// 单测(test/notification_actions_test.dart)据此校验。
library;

import 'queue.dart';

/// 通知栏「播放顺序」按钮的轮转顺序(列表循环→单曲循环→顺序播放→随机播放→回到列表循环)。
///
/// **心动模式/私人FM 不在这个轮转里**(2026-11-19 用户反馈 4/5/6): 它们是「引导态」
/// ([QueueGuide]), 有自己的入口(推荐页卡片)和自己的续播逻辑, 与播放顺序互不干扰。
/// 以前的实现用返回 null 表示「下一步进心动模式」, 于是随机播放之后必然把用户拖进
/// 心动模式(FM 也是靠 PlayMode 轮转进来的), 这正是用户说的「播放顺序干扰了它们」。
/// 纯函数, 便于单测。
PlayMode nextNotificationMode(PlayMode mode) {
  const order = [
    PlayMode.repeatAll,
    PlayMode.repeatOne,
    PlayMode.sequence,
    PlayMode.shuffle,
  ];
  final i = order.indexOf(mode);
  return order[(i + 1) % order.length];
}

/// 通知栏模式按钮的图标名(与 Kotlin 侧 `modeIconRes` 对齐)。
///
/// 优先级: 私人FM > 心动模式 > [PlayMode](引导态下播放顺序是"退出引导"的按钮,
/// 图标必须说明当前处在哪个引导态)。
/// - `'fm'` → Kotlin `ic_notif_fm`(广播图标)
/// - `'heart'` → Kotlin `ic_notif_heart_fire`(**火焰**, 与喜欢按钮的红心
///   `ic_notif_heart_filled` 分开; 2026-11-19 用户反馈 6: 两者同图分不清)
String notificationModeIcon(
  PlayMode mode, {
  bool heartActive = false,
  bool fmActive = false,
}) {
  if (fmActive) return 'fm';
  if (heartActive) return 'heart';
  return switch (mode) {
    PlayMode.repeatAll => 'repeat',
    PlayMode.repeatOne => 'repeatOne',
    PlayMode.sequence => 'sequence',
    PlayMode.shuffle => 'shuffle',
  };
}
