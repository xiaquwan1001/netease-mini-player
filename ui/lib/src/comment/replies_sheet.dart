part of 'comment_thread.dart';

/// 楼层: 某条评论的回复列表 + 底部输入框发回复
class _RepliesSheet extends StatefulWidget {
  const _RepliesSheet({
    required this.parent,
    required this.load,
    required this.reply,
    this.focusComposer = false,
  });

  final rust.Comment parent;
  final CommentRepliesLoader load;
  final CommentReplyHook reply;

  /// true = 「回复」动作打开: 直接聚焦输入框进写回复
  final bool focusComposer;

  @override
  State<_RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<_RepliesSheet> {
  static const _limit = 20;
  final TextEditingController _controller = TextEditingController();

  /// 发送失败的提示。改造前写进 `_error`, 而那个位置只在「整块加载失败」时显示,
  /// 列表已经加载出来时发送失败等于静默; 现在单独留一处, 贴在输入框上方。
  String? _sendError;
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// [AsyncView] 的取数入口(组件自己套 [retryNetwork]): 楼层回复一次全量返回,
  /// 无游标不分页。
  Future<List<rust.Comment>> _load() async {
    final page = await widget.load(widget.parent.id, _limit);
    return page.comments;
  }

  Future<void> _send() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      await widget.reply(widget.parent.id, content);
      if (!mounted) return;
      _controller.clear();
      FocusScope.of(context).unfocus();
      // 不在面板里再重拉一次(结果在 pop 前看不到): 回传 true, 由外层本地 +1
      // 并重取行内预览。
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题统一走 SheetHeader(与其它弹层一致): 楼层面板把被回复的内容当副标题
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SheetHeader(
                title: '回复',
                subtitle: '${widget.parent.userName}: ${widget.parent.content}',
              ),
            ),
            const Divider(height: 1),
            // 非分页: 楼层回复一次全量返回, 无游标。四态收敛到 AsyncView:
            // 加载中 = LoadingView, 空态 = EmptyView, 出错 = 只有一行错误文案
            // (改造前就是这个形态, 这里不新增重试按钮), 有数据 = 回复列表。
            Expanded(
              child: AsyncView<List<rust.Comment>>(
                load: _load,
                emptyText: '还没有回复',
                loadingBuilder: (_) => const LoadingView(),
                emptyBuilder: (_) => const EmptyView(title: '还没有回复'),
                errorBuilder: (context, error, _) => Center(
                  child: Text(
                    friendlyError(error),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
                builder: (context, replies, _) =>
                    _buildReplies(context, replies),
              ),
            ),
            if (_sendError != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 2),
                child: Text(
                  _sendError!,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: widget.focusComposer,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        decoration: const InputDecoration(
                          isDense: true,
                          hintText: '回复这条评论…',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _sending ? null : _send,
                      child: _sending
                          ? const LoadingView.inline(size: 16)
                          : const Text('发送'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 回复列表(四态已由 AsyncView 判完, 这里只画有数据的形态)
  Widget _buildReplies(BuildContext context, List<rust.Comment> replies) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: replies.length,
      itemBuilder: (context, i) {
        final r = replies[i];
        return ListTile(
          dense: true,
          // 与主楼评论(12+2+32+8)对齐: 收窄 contentPadding,
          // leading 固定 32 槽, 避免楼层面板文字比主楼右移一截。
          contentPadding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
          leading: SizedBox(
            width: 32,
            child: UserAvatarTap(
              userId: r.userId,
              nickname: r.userName,
              child: CircleCover(
                url: r.avatarUrl,
                size: 28,
                icon: Icons.person_outline,
              ),
            ),
          ),
          title: Text(
            r.userName.isEmpty ? '匿名用户' : r.userName,
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary),
          ),
          subtitle: Text(
            (r.repliedTo ?? '').isEmpty
                ? r.content
                : '回复 @${r.repliedTo}：${r.content}',
          ),
        );
      },
    );
  }
}
