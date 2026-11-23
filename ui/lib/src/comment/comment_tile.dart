part of 'comment_thread.dart';

class _CommentTile extends StatefulWidget {
  const _CommentTile({
    super.key,
    required this.comment,
    this.shareSourceTitle = '',
    this.shareSourceKind = '',
    required this.timeText,
    required this.onToggleLike,
    required this.onExpandReplies,
    required this.onReply,
    this.previewReplies = const [],
    this.onDelete,
    this.highlight = false,
  });

  /// 刚发表的那条: 短暂高亮底色, 让人一眼看到自己发的评论
  final bool highlight;

  final rust.Comment comment;

  /// 长按分享时卡片底部的出处(原动态标题/正文摘要)
  final String shareSourceTitle;

  /// 出处的类型词(歌曲/歌单/专辑/播客/动态)
  final String shareSourceKind;
  final String timeText;
  final VoidCallback onToggleLike;

  /// 看全部回复: 预览行与「展开全部 N 条回复」入口共用
  final VoidCallback onExpandReplies;

  /// 直接进写回复(面板打开即聚焦输入框)
  final VoidCallback onReply;

  /// 行内预览的前 K 条回复(顶层 tile 专用; 楼层预览失败时为空)
  final List<rust.Comment> previewReplies;

  /// 只有自己发的评论才给(别人的评论官方也不允许删)
  final VoidCallback? onDelete;

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

/// 长按评论要有与「回复」按钮同源的选中反馈(需求: 长按唤起转发时评论本身
/// 没有"选中"动态效果): 用与刚发表评论高亮同一套 primaryContainer 底色,
/// 长按期间点亮, 松手/定时褪去。
class _CommentTileState extends State<_CommentTile> {
  /// 长按进行中(分享面板打开前后的按压态)
  bool _pressed = false;

  /// 长按已触发分享面板(此时框架会立刻 cancel 掉本手势, 选中态交给定时器褪色)
  bool _sheetOpened = false;
  Timer? _pressedTimer;

  void _setPressed(bool value) {
    if (!mounted) return;
    setState(() => _pressed = value);
    _pressedTimer?.cancel();
    _pressedTimer = value
        ? Timer(const Duration(milliseconds: 1500), () {
            if (mounted) setState(() => _pressed = false);
          })
        : null;
  }

  @override
  void dispose() {
    _pressedTimer?.cancel();
    super.dispose();
  }

  /// 「展开全部 N 条回复」里的 N: 服务端计数与本地已拿到条数取大
  BigInt get _replyTotal {
    final local = BigInt.from(widget.previewReplies.length);
    return widget.comment.replyCount > local
        ? widget.comment.replyCount
        : local;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final comment = widget.comment;
    final highlight = widget.highlight;
    final timeText = widget.timeText;
    final onToggleLike = widget.onToggleLike;
    final onExpandReplies = widget.onExpandReplies;
    final onReply = widget.onReply;
    final previewReplies = widget.previewReplies;
    final onDelete = widget.onDelete;
    return GestureDetector(
      // 长按评论 = 分享评论卡片(作者 + 正文 + 出处语境 + 点赞/回复数)
      onLongPress: () {
        _sheetOpened = true;
        showCommentShareSheet(
          context,
          comment: comment,
          sourceTitle: widget.shareSourceTitle,
          sourceKindLabel: widget.shareSourceKind,
        );
      },
      // 长按期间点亮整条评论(与高亮同款底色 token), 松手/定时褪去
      onLongPressStart: (_) => _setPressed(true),
      onLongPressEnd: (_) => _setPressed(false),
      // 分享面板弹出时框架会立刻取消本手势, 此时选中态正要展示, 不能清
      onLongPressCancel: () {
        if (!_sheetOpened) _setPressed(false);
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        // 刚发表的那条淡出一层底色, 1.8s 后由父级把 highlight 置回 false;
        // 长按分享时同一套底色作为"选中"态
        decoration: BoxDecoration(
          color: highlight || _pressed
              ? scheme.primaryContainer.withValues(alpha: 0.45)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.only(bottom: 12, top: 2, left: 2, right: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserAvatarTap(
              userId: comment.userId,
              nickname: comment.userName,
              child: CircleCover(
                url: comment.avatarUrl,
                size: 32,
                icon: Icons.person_outline,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          comment.userName.isEmpty ? '匿名用户' : comment.userName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ),
                      // 楼层里的回复: 不显示"回复 @某人"就跟独立评论长得一样
                      if ((comment.repliedTo ?? '').isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '回复 @${comment.repliedTo}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                      // 单条的「热门」小标签已删除(2026-11-23 用户口径):
                      // 每条已有互动数(点赞数), 而且评论区顶部的「热门」页签已经
                      // 表达了同一件事 —— 标签重复, 还会挤掉昵称宽度(300dp 折行问题)。
                      // 时间/IP 是裸 Text 时占满自身宽度且不可压缩: 昵称与「回复 @x」
                      // 已被压到最小后, 这两段相加仍会撑破整行(300dp x1.625 必现)。
                      // 包 Flexible 让它们参与同一套宽度分配, 极端窄屏才截断。
                      if (timeText.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            timeText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ),
                      ],
                      if (comment.ipLocation.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            comment.ipLocation,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.outline,
                            ),
                          ),
                        ),
                      ],
                      // 点赞(需求: 与用户名/发布时间同行, 时间右侧, 展示数量,
                      // 0 也显示): 与「回复」按钮同一套颜色/描边 token
                      const Spacer(),
                      InkWell(
                        onTap: onToggleLike,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                comment.liked
                                    ? Icons.favorite
                                    : Icons.favorite_border,
                                size: 14,
                                color: comment.liked
                                    ? scheme.primary
                                    : scheme.outline,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '${comment.likedCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: comment.liked
                                      ? scheme.primary
                                      : scheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(comment.content, style: theme.textTheme.bodyMedium),
                  // 行内回复预览: 缩进 + 小头像, 跟楼层里的排布一致(一眼看出是"对话"而不是
                  // 平铺的一段文字); 点任意一条 → 打开楼层详情(与「回复」动作分离见下)
                  if (previewReplies.isNotEmpty)
                    Container(
                      margin: const EdgeInsets.only(top: 4, left: 4),
                      padding: const EdgeInsets.only(left: 8),
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: scheme.outlineVariant,
                            width: 2,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final r in previewReplies)
                            InkWell(
                              onTap: onExpandReplies,
                              borderRadius: BorderRadius.circular(6),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 3,
                                ),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    UserAvatarTap(
                                      userId: r.userId,
                                      nickname: r.userName,
                                      child: CircleCover(
                                        url: r.avatarUrl,
                                        size: 18,
                                        icon: Icons.person_outline,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        // 有被回复者就带上, 没写就是直接回主评论
                                        (r.repliedTo ?? '').isEmpty
                                            ? '${r.userName.isEmpty ? '匿名用户' : r.userName}：${r.content}'
                                            : '${r.userName.isEmpty ? '匿名用户' : r.userName} 回复 @${r.repliedTo}：${r.content}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  // 展开入口只在"行内放不下"时出现: 回复 ≤3 条已经全部缩进展示, 再给按钮就是
                  // 冗余(用户实测: 1 条回复也顶着「展开全部 1 条回复」)。N 取
                  // max(服务端 replyCount, 本地条数) —— 接口有时 replyCount 为 0 却仍返回回复。
                  if (_replyTotal > BigInt.from(previewReplies.length))
                    InkWell(
                      onTap: onExpandReplies,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '展开全部 $_replyTotal 条回复',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 2),
                  // 动作数量随权限变化(「删除」只有自己发的评论才有),
                  // 4 个图标+文字+间距在 300dp x1.625 下必然超出卡片宽度。
                  // 用 Wrap 让多出的动作换到下一行: 不做横向滚动, 否则「删除」会被
                  // 推到屏幕外且没有任何可滚动提示。
                  Wrap(
                    spacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // 点赞已上移到「用户名 + 发布时间」行(见头行右端), 动作行
                      // 只留回复/删除。
                      // 「回复」= 写回复动作本体(打开面板并聚焦输入框);
                      // 数量与浏览全量回复由预览行/「展开全部」承担, 不再混在一个按钮里。
                      InkWell(
                        onTap: onReply,
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 2,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.mode_comment_outlined,
                                size: 14,
                                color: scheme.outline,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                '回复',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (onDelete != null)
                        InkWell(
                          onTap: onDelete,
                          borderRadius: BorderRadius.circular(6),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete_outline,
                                  size: 14,
                                  color: scheme.outline,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '删除',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: scheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
