import 'package:flutter/material.dart';

/// 统一 SnackBar 提示: 先收起旧的再弹, 避免排队连弹.
///
/// - `showToast(context, msg)`: 日常提示(悬浮 + 3 秒自动回落).
/// - `isError: true`: 失败提示, 用 error 底色.
/// - 弹层 pop 之后才提示的场景, 先拿住 messenger 再用
///   `showToastWith`, 避免 context 失效.
void showToast(BuildContext context, String message, {bool isError = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  showToastWith(messenger, message, isError: isError);
}

/// 提示条统一配称: 悬浮(不贴底、不盖住播放条) + 3 秒自动回落 + 可横扫关闭.
///
/// 用户反馈「取关/取消喜欢的弹窗不会自动回落, 遮挡内容」: 根因是默认的
/// fixed SnackBar 贴在底部、和常驻播放条叠在一起, 而且 4~5 秒的存在感很长。
/// 现在统一 floating + 3 秒, 且**默认没有 action**(有 action 的撤销条会让人觉得
/// 不走就一直在), 只有真正高代价的写操作才给撤销(见 [showUndoToast])。
const Duration kToastDuration = Duration(seconds: 3);

SnackBar _toastBar(
  String message, {
  Color? background,
  SnackBarAction? action,
  Duration duration = kToastDuration,
}) {
  return SnackBar(
    content: Text(message),
    duration: duration,
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    dismissDirection: DismissDirection.horizontal,
    backgroundColor: background,
    action: action,
  );
}

void showToastWith(
  ScaffoldMessengerState messenger,
  String message, {
  bool isError = false,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      _toastBar(
        message,
        background: isError
            ? Theme.of(messenger.context).colorScheme.error
            : null,
      ),
    );
}

/// 可撤销操作的横条: 默认 5 秒, 期间点「撤销」执行 [onUndo].
///
/// 只用于**有明确反向操作**的写动作(取消喜欢 / 取消收藏歌单 / 取消关注):
/// 正向动作(喜欢/收藏/关注)不给撤销 —— 官方客户端也没有, 且撤销一次收藏
/// 再撤销一次等于把用户的误触放大成两次网络写请求。
void showUndoToast(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
  Duration duration = const Duration(seconds: 4),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      _toastBar(
        message,
        duration: duration,
        action: SnackBarAction(label: '撤销', onPressed: onUndo),
      ),
    );
}
