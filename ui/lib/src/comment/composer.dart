part of 'comment_thread.dart';

/// 评论区底部"写评论"入口(点击打开输入面板)。
class _ComposerBar extends StatelessWidget {
  const _ComposerBar({required this.enabled, required this.onTap});

  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(
                  Icons.edit_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    enabled ? '写评论…' : '评论暂时不可用',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Icon(
                  Icons.send,
                  size: 18,
                  color: enabled ? scheme.primary : scheme.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 发表顶层评论的输入面板: TextField + 发送(不新增 FFI, 发送走 [submit])。
///
/// 键盘避让: 面板整体按 MediaQuery.viewInsets.bottom 抬升。它是
/// isScrollControlled 的 bottom sheet, 高度随内容撑开, 底部再垫键盘高度,
/// 所以输入框始终贴在键盘上沿 —— 从详情页的评论区弹层里打开也一样。
class _ComposeSheet extends StatefulWidget {
  const _ComposeSheet({required this.submit});

  /// 真正的发送动作(父级做乐观插入 + 失败回滚); 抛异常 = 失败
  final Future<void> Function(String content) submit;

  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 空文本 / 发送中都不给发
  bool get _canSend => !_sending && _controller.text.trim().isNotEmpty;

  Future<void> _send() async {
    if (!_canSend) return;
    final content = _controller.text.trim();
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.submit(content);
      if (!mounted) return;
      _controller.clear();
      FocusScope.of(context).unfocus();
      Navigator.of(context).pop();
    } catch (e) {
      // 失败: 保留已输入文本, 原地给 friendlyError, 按钮恢复可点(= 重试)
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      // 键盘避让(弹层内打开同样生效)
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SheetHeader(title: '写评论'),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                autofocus: true,
                minLines: 1,
                maxLines: 4,
                maxLength: 140,
                textInputAction: TextInputAction.newline,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '说点什么…',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 6),
                Text(
                  _error!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _sending
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _canSend ? _send : null,
                    child: _sending
                        ? const LoadingView.inline(size: 16)
                        : const Text('发送'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
