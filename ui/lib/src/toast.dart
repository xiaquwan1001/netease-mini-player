import 'package:flutter/material.dart';

/// 统一 SnackBar 提示: 先收起旧的再弹, 避免排队连弹.
///
/// - `showToast(context, msg)`: 日常提示(默认样式).
/// - `isError: true`: 失败提示, 用 error 底色.
/// - 弹层 pop 之后才提示的场景, 先拿住 messenger 再用
///   `showToastWith`, 避免 context 失效.
void showToast(BuildContext context, String message, {bool isError = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  showToastWith(messenger, message, isError: isError);
}

void showToastWith(
  ScaffoldMessengerState messenger,
  String message, {
  bool isError = false,
}) {
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
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
  Duration duration = const Duration(seconds: 5),
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        duration: duration,
        action: SnackBarAction(label: '撤销', onPressed: onUndo),
      ),
    );
}
