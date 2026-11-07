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
        backgroundColor:
            isError ? Theme.of(messenger.context).colorScheme.error : null,
      ),
    );
}
