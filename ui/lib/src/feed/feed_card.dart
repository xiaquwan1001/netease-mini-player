part of 'feed_view_body.dart';

/// 一条动态卡片(摘要; 点整卡进详情页)
class _FeedCard extends StatelessWidget {
  const _FeedCard({
    required this.event,
    required this.onOpenUrl,
    required this.onOpenChanged,
    required this.onLike,
    this.forwardEvent,
  });

  final rust.FeedEventDto event;
  final Future<void> Function(String url) onOpenUrl;
  final void Function(rust.FeedEventDto updated) onOpenChanged;

  /// 列表行点赞(乐观更新/回滚在 FeedView 的列表状态里做)
  final VoidCallback onLike;

  /// 转发动作(分享面板"转发动态"), 默认 rust.forwardEvent
  final Future<bool> Function({
    required BigInt eventId,
    required BigInt userId,
    required String msg,
  })?
  forwardEvent;

  /// 分享面板(与详情页同源): 预览卡片 + 水印/二维码开关 + 系统分享/保存图片/
  /// 复制链接/转发动态。转发走 forwardEvent 注入(默认 rust.forwardEvent)。
  Future<void> _openShareSheet(BuildContext context) {
    return showFeedShareSheet(
      context,
      event: event,
      forwardEvent: forwardEvent,
    );
  }

  Future<void> _openDetail(
    BuildContext context, {
    bool focusComments = false,
  }) async {
    await showFeedDetail(
      context,
      event: event,
      onOpenUrl: onOpenUrl,
      // 从"评论"数字/图标进来时直接定位到评论区(不弹输入框)
      focusComments: focusComments,
      onLikeChanged: (id, liked, likedCount) => onOpenChanged(
        _copyEventWith(event, liked: liked, likedCount: likedCount),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasBody =
        event.text.trim().isNotEmpty ||
        event.title.trim().isNotEmpty ||
        event.song != null ||
        event.images.isNotEmpty ||
        event.videoUrl != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(context),
        // 长按与分享按钮走同一个统一分享面板(转发动态是面板里的一项动作,
        // 不再单独弹转发面板, 与详情页动作区同源 —— 需求"统一转发 UI")
        onLongPress: () => _openShareSheet(context),
        child: Padding(
          // 页面 12 + 卡片 8 = 20dp/侧: 动态是正文流, 太宽会明显浪费横向空间
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部: 头像 + 用户名 + kind 标签 + 相对时间
              Row(
                children: [
                  UserAvatarTap(
                    userId: event.userId,
                    nickname: event.userName,
                    child: CircleCover(url: event.avatarUrl, size: 40),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      event.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // 原先这里有个「单曲 / 动态」kind 徽标: 用户反馈它不提供额外信息
                  // (点进详情就能看出来), 已去掉, 横向空间让给用户名与时间。
                  const SizedBox(width: 8),
                  // 时间是不可收缩的定宽尾部元素(与「我的」/消息页一致):
                  // 横向空间不足时先让用户名(Expanded)截断, 时间保持完整可读。
                  // maxLines/overflow 只兜底"时间本身比整行还宽"的极端字号。
                  Text(
                    feedRelativeTime(event.timeMs),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
              // 正文(最多 4 行, 详情页看全文)
              if (event.text.trim().isNotEmpty)
                Padding(
                  // 顶格(与卡片左缘对齐): 之前 left:50 想对齐用户名, 但头像 40 +
                  // 间距 10 的那一列在窄屏上会明显内缩, 正文每行前面多一段空白
                  // (用户反馈"动态文字左边有空白缩进, 应该取消").
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    event.text.trim(),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              // 单曲 mini 卡
              if (event.song != null)
                FeedSongMiniCard(song: event.song!, coverUrl: event.coverUrl),
              // 配图: 只放用户自己附的照片, 排版按张数(1 张大图 / 2 两列 / 3+ 三列)
              if (feedAttachedImages(event).isNotEmpty) ...[
                const SizedBox(height: 8),
                FeedImageGrid(images: feedAttachedImages(event)),
              ],
              // 视频: 16:9 封面 + 播放圆标 + 右上角标签, 点击交给系统打开
              if (event.videoUrl != null) ...[
                const SizedBox(height: 8),
                FeedVideoThumb(
                  url: event.videoUrl!,
                  coverUrl: event.coverUrl,
                  onOpenUrl: onOpenUrl,
                ),
              ],
              if (hasBody) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    // 点赞: 可点, 乐观翻转(变色/变数), 失败由 FeedView 回滚
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: onLike,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              event.liked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 14,
                              color: event.liked
                                  ? scheme.primary
                                  : scheme.outline,
                            ),
                            if (event.likedCount > BigInt.zero) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${event.likedCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: event.liked
                                      ? scheme.primary
                                      : scheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // 评论: 点数字/图标进详情并直接滚到评论区
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _openDetail(context, focusComments: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.mode_comment_outlined,
                              size: 14,
                              color: scheme.outline,
                            ),
                            if (event.commentCount > BigInt.zero) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${event.commentCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 分享: 动作面板(转发 / 复制链接)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _openShareSheet(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.autorenew,
                              size: 14,
                              color: scheme.outline,
                            ),
                            if (event.shareCount > BigInt.zero) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${event.shareCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // 空间紧张(300dp+1.25)时"查看详情"缩放让位, 不溢出
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '查看详情',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.outline,
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: scheme.outline,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
