import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 评论线程: 列表 + 点赞 + 楼层回复 + 发回复.
///
/// 两种入口共用一套 UI:
/// - 歌曲/歌单/专辑/播客: 传 [kind] + [resourceId](内部走 rust.comments)
/// - 动态: 传 [threadId](内部走 rust.eventComments)
/// 点赞/回复统一用 CommentPage.threadId。
typedef CommentPageLoader = Future<rust.CommentPageDto> Function(
    int limit, int offset);
typedef CommentLikeHook = Future<bool> Function(BigInt commentId, bool liked);
typedef CommentRepliesLoader = Future<rust.CommentPageDto> Function(
    BigInt parentId, int limit);
typedef CommentReplyHook = Future<bool> Function(
    BigInt commentId, String content);
typedef CommentDeleteHook = Future<bool> Function(BigInt commentId);

class CommentThread extends StatefulWidget {
  const CommentThread({
    super.key,
    this.kind,
    this.resourceId,
    this.threadId,
    this.totalHint = 0,
    this.title = '评论',
    this.pageSize = 10,
    this.loadPage,
    this.loadHot,
    this.like,
    this.loadReplies,
    this.reply,
    this.delete,
    this.myUid,
  });

  /// song | playlist | album | podcast
  final String? kind;
  final BigInt? resourceId;

  /// 动态评论的 threadId(给了它就不看 kind/resourceId)
  final String? threadId;
  final int totalHint;
  final String title;
  final int pageSize;

  final CommentPageLoader? loadPage;

  /// 热门评论加载器(不传就走 rust.hotComments). 动态评论不支持热门, 传空即可
  final CommentPageLoader? loadHot;
  final CommentLikeHook? like;
  final CommentRepliesLoader? loadReplies;
  final CommentReplyHook? reply;

  /// 删除自己的评论(不传就走 rust.deleteComment)
  final CommentDeleteHook? delete;

  /// 当前账号 uid(测试注入); 不传就向 Rust 要. 决定哪些评论显示"删除".
  final BigInt? myUid;

  @override
  State<CommentThread> createState() => _CommentThreadState();
}

class _CommentThreadState extends State<CommentThread> {
  final List<rust.CommentDto> _items = <rust.CommentDto>[];
  BigInt _total = BigInt.zero;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  String? _moreError;

  /// 点赞/回复/删除都要用它(来自第一页)
  String _threadId = '';

  /// false = 全部(精彩评论 + 最新, 接口默认页), true = 只看精彩评论
  bool _hot = false;

  /// 当前账号 uid(0 = 未登录): 只有自己发的评论才给"删除"
  BigInt _myUid = BigInt.zero;

  CommentPageLoader get _loadPage =>
      widget.loadPage ??
      (limit, offset) {
        final tid = widget.threadId;
        if (tid != null) {
          return rust.eventComments(threadId: tid, limit: limit, offset: offset);
        }
        return rust.comments(
          kind: widget.kind!,
          resourceId: widget.resourceId!,
          limit: limit,
          offset: offset,
        );
      };

  CommentPageLoader get _loadHotPage =>
      widget.loadHot ??
      (limit, offset) => rust.hotComments(
            threadId: _threadId,
            limit: limit,
            offset: offset,
          );

  /// 当前页签对应的加载器: 全部走默认页, 热门走 comment_hot
  CommentPageLoader get _fetchPage =>
      _hot ? _loadHotPage : _loadPage;

  CommentLikeHook get _like =>
      widget.like ??
      (commentId, liked) => rust.likeComment(
            threadId: _threadId,
            commentId: commentId,
            liked: liked,
          );

  CommentRepliesLoader get _loadReplies =>
      widget.loadReplies ??
      (parentId, limit) => rust.commentReplies(
            threadId: _threadId,
            parentCommentId: parentId,
            limit: limit,
          );

  CommentReplyHook get _reply =>
      widget.reply ??
      (commentId, content) => rust.replyComment(
            threadId: _threadId,
            commentId: commentId,
            content: content,
          );

  CommentDeleteHook get _delete =>
      widget.delete ??
      (commentId) => rust.deleteComment(
            threadId: _threadId,
            commentId: commentId,
          );

  @override
  void initState() {
    super.initState();
    _threadId = widget.threadId ?? '';
    final injected = widget.myUid;
    if (injected != null && injected != BigInt.zero) _myUid = injected;
    _reload();
    if (injected == null) _loadMyUid();
  }

  Future<void> _loadMyUid() async {
    try {
      final uid = await rust.myUid();
      if (!mounted || uid == BigInt.zero) return;
      setState(() => _myUid = uid);
    } catch (_) {
      // 未登录: 不显示删除入口
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _moreError = null;
    });
    try {
      final page = await retryNetwork(() => _fetchPage(widget.pageSize, 0));
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.comments);
        _total = page.total;
        _hasMore = page.hasMore;
        if (page.threadId.isNotEmpty) _threadId = page.threadId;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyError(e);
        _loading = false;
      });
    }
  }

  /// "全部"页的 offset 只能数"最新评论"(接口的 offset 作用在 latest 上,
  /// 精彩评论每次都随首页一起返回; 用 items.length 会把位置算多, 还会重复拉热评)
  int get _nextOffset =>
      _hot ? _items.length : _items.where((c) => !c.hot).length;

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() {
      _loadingMore = true;
      _moreError = null;
    });
    try {
      final page = await retryNetwork(
        () => _fetchPage(widget.pageSize, _nextOffset),
      );
      if (!mounted) return;
      setState(() {
        // 兜底去重: 同一页里热评可能再次出现
        final seen = _items.map((c) => c.id).toSet();
        _items.addAll(page.comments.where((c) => seen.add(c.id)));
        _total = page.total;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _moreError = friendlyError(e);
      });
    }
  }

  /// 点赞: 先本地乐观翻转, 失败回滚
  Future<void> _toggleLike(int index) async {
    final c = _items[index];
    final target = !c.liked;
    final delta = target ? 1 : -1;
    setState(() {
      _items[index] = _copy(c, liked: target, likedDelta: delta);
    });
    try {
      await _like(c.id, target);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items[index] = _copy(c, liked: c.liked, likedDelta: 0);
      });
      _snack('点赞失败: ${friendlyError(e)}');
    }
  }

  rust.CommentDto _copy(
    rust.CommentDto c, {
    required bool liked,
    required int likedDelta,
  }) {
    final count = c.likedCount + BigInt.from(likedDelta);
    return rust.CommentDto(
      id: c.id,
      userId: c.userId,
      userName: c.userName,
      avatarUrl: c.avatarUrl,
      content: c.content,
      timeMs: c.timeMs,
      likedCount: count < BigInt.zero ? BigInt.zero : count,
      liked: liked,
      replyCount: c.replyCount,
      ipLocation: c.ipLocation,
      hot: c.hot,
    );
  }

  Future<void> _openReplies(rust.CommentDto comment) async {
    final sent = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _RepliesSheet(
        parent: comment,
        load: _loadReplies,
        reply: _reply,
      ),
    );
    if (sent != true || !mounted) return;
    final index = _items.indexWhere((c) => c.id == comment.id);
    if (index < 0) return;
    setState(() {
      final c = _items[index];
      _items[index] = rust.CommentDto(
        id: c.id,
        userId: c.userId,
        userName: c.userName,
        avatarUrl: c.avatarUrl,
        content: c.content,
        timeMs: c.timeMs,
        likedCount: c.likedCount,
        liked: c.liked,
        replyCount: c.replyCount + BigInt.one,
        ipLocation: c.ipLocation,
        hot: c.hot,
      );
    });
  }

  /// 删除自己发的评论: 先确认, 成功后本地移除(不整页刷新)
  Future<void> _deleteComment(int index) async {
    final comment = _items[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这条评论?'),
        content: Text(
          comment.content.length > 60
              ? '${comment.content.substring(0, 60)}...'
              : comment.content,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _delete(comment.id);
      if (!mounted) return;
      setState(() {
        _items.removeAt(index);
        if (_total > BigInt.zero) _total -= BigInt.one;
      });
      _snack('已删除');
    } catch (e) {
      _snack('删除失败: ${friendlyError(e)}');
    }
  }

  /// 只有资源类评论(歌曲/歌单/专辑/播客)能查热门; 动态评论的 threadId 带 uid, 接口不认
  bool get _supportsHot => widget.kind != null || widget.loadHot != null;

  bool get _canHot => _threadId.isNotEmpty || widget.loadHot != null;

  /// 切"全部/热门": 换加载器并整页重载
  void _switchMode(bool hot) {
    if (_hot == hot) return;
    setState(() {
      _hot = hot;
      _items.clear();
      _total = BigInt.zero;
      _hasMore = false;
    });
    _reload();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _relative(BigInt timeMs) {
    if (timeMs <= BigInt.zero) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(timeMs.toInt());
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = (_loading || _error != null) && _total == BigInt.zero
        ? BigInt.from(widget.totalHint)
        : _total;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                widget.title,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (count > BigInt.zero) ...[
                const SizedBox(width: 6),
                Text(
                  '$count',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
          if (_supportsHot) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              children: [
                ChoiceChip(
                  label: const Text('全部'),
                  selected: !_hot,
                  onSelected: (_) => _switchMode(false),
                ),
                ChoiceChip(
                  label: const Text('热门'),
                  selected: _hot,
                  onSelected: _canHot ? (_) => _switchMode(true) : null,
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (_error != null)
            Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(color: scheme.error, fontSize: 12),
                  ),
                ),
                TextButton(onPressed: _reload, child: const Text('重试')),
              ],
            )
          else if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('还没有评论', style: theme.textTheme.bodySmall),
            )
          else
            for (var i = 0; i < _items.length; i++)
              _CommentTile(
                comment: _items[i],
                timeText: _relative(_items[i].timeMs),
                onToggleLike: () => _toggleLike(i),
                onOpenReplies: () => _openReplies(_items[i]),
                onDelete: _myUid != BigInt.zero && _items[i].userId == _myUid
                    ? () => _deleteComment(i)
                    : null,
              ),
          if (!_loading && _error == null && _items.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_loadingMore)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (_moreError != null)
                  TextButton(
                    onPressed: _loadMore,
                    child: Text(
                      '${_moreError!} (重试)',
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  )
                else if (_hasMore)
                  TextButton(onPressed: _loadMore, child: const Text('加载更多评论')),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.comment,
    required this.timeText,
    required this.onToggleLike,
    required this.onOpenReplies,
    this.onDelete,
  });

  final rust.CommentDto comment;
  final String timeText;
  final VoidCallback onToggleLike;
  final VoidCallback onOpenReplies;

  /// 只有自己发的评论才给(别人的评论官方也不允许删)
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleCover(
            url: comment.avatarUrl,
            size: 32,
            icon: Icons.person_outline,
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
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.primary),
                      ),
                    ),
                    if (comment.hot) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '热门',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                    if (timeText.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        timeText,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                    if (comment.ipLocation.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        comment.ipLocation,
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(comment.content, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Row(
                  children: [
                    InkWell(
                      onTap: onToggleLike,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
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
                            if (comment.likedCount > BigInt.zero) ...[
                              const SizedBox(width: 3),
                              Text(
                                '${comment.likedCount}',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: scheme.outline),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    InkWell(
                      onTap: onOpenReplies,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.mode_comment_outlined,
                                size: 14, color: scheme.outline),
                            const SizedBox(width: 3),
                            Text(
                              comment.replyCount > BigInt.zero
                                  ? '回复 ${comment.replyCount}'
                                  : '回复',
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: scheme.outline),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (onDelete != null) ...[
                      const SizedBox(width: 10),
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
                              Icon(Icons.delete_outline,
                                  size: 14, color: scheme.outline),
                              const SizedBox(width: 3),
                              Text(
                                '删除',
                                style: theme.textTheme.labelSmall
                                    ?.copyWith(color: scheme.outline),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 楼层: 某条评论的回复列表 + 底部输入框发回复
class _RepliesSheet extends StatefulWidget {
  const _RepliesSheet({
    required this.parent,
    required this.load,
    required this.reply,
  });

  final rust.CommentDto parent;
  final CommentRepliesLoader load;
  final CommentReplyHook reply;

  @override
  State<_RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<_RepliesSheet> {
  static const _limit = 20;
  final TextEditingController _controller = TextEditingController();
  List<rust.CommentDto>? _replies;
  String? _error;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final page = await retryNetwork(() => widget.load(widget.parent.id, _limit));
      if (!mounted) return;
      setState(() => _replies = page.comments);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _send() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.reply(widget.parent.id, content);
      if (!mounted) return;
      _controller.clear();
      FocusScope.of(context).unfocus();
      await _load();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
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
    final replies = _replies;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '回复',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${widget.parent.userName}: ${widget.parent.content}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: replies == null
                  ? (_error == null
                      ? const Center(child: CircularProgressIndicator())
                      : Center(
                          child: Text(
                            _error!,
                            style: TextStyle(color: scheme.error, fontSize: 12),
                          ),
                        ))
                  : replies.isEmpty
                      ? Center(
                          child: Text('还没有回复', style: theme.textTheme.bodySmall),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: replies.length,
                          itemBuilder: (context, i) {
                            final r = replies[i];
                            return ListTile(
                              dense: true,
                              leading: CircleCover(
                                url: r.avatarUrl,
                                size: 28,
                                icon: Icons.person_outline,
                              ),
                              title: Text(
                                r.userName.isEmpty ? '匿名用户' : r.userName,
                                style: theme.textTheme.labelMedium
                                    ?.copyWith(color: scheme.primary),
                              ),
                              subtitle: Text(r.content),
                            );
                          },
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
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
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
}
