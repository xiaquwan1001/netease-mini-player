import 'package:flutter/material.dart';

/// 统一的错误态视图, 收敛各页各写一份的 `_InlineError` / `_ErrorView`.
///
/// 视觉与原各页私有实现保持一致, 替换时只改类名不改口径.

/// 行内错误: 一行错误文案 + 右侧重试按钮(嵌在列表/区块中间时用).
class InlineError extends StatelessWidget {
  const InlineError({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
          ),
        ),
        TextButton(onPressed: onRetry, child: const Text('重试')),
      ],
    );
  }
}

/// 整块/首屏错误: 居中文案 + 重试主按钮.
class FullError extends StatelessWidget {
  const FullError({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
