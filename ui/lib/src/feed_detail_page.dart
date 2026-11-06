import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 动态详情页: 完整正文 / 配图 / 视频 / 单曲卡 + 点赞·转发 + 评论区.
///
/// 关注流里的卡片只展示摘要, 点开走这里。所有网络动作失败都只在本页提示,
/// 不把异常抛给调用方(动态本身是只读内容, 操作失败不影响浏览)。
Future<void> showFeedDetail(
  BuildContext context, {
  required rust.FeedEventDto event,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  required Future<void> Function(String url) onOpenUrl,
  void Function(BigInt eventId, bool liked, BigInt likedCount)? onLikeChanged,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _FeedDetailPage(
        event: event,
        onPlaySongs: onPlaySongs,
        onOpenUrl: onOpenUrl,
        onLikeChanged: onLikeChanged,
      ),
    ),
  );
}

String feedRelativeTime(BigInt timeMs) {
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

const Map<String, String> feedKindLabels = {
  'song': '单曲',
  'playlist': '歌单',
  'album': '专辑',
  'program': '节目',
  'text': '动态',
  'other': '动态',
};

class _FeedDetailPage extends StatefulWidget {
  const _FeedDetailPage({
    required this.event,
    required this.onPlaySongs,
    required this.onOpenUrl,
    this.onLikeChanged,
  });

  final rust.FeedEventDto event;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;
  final void Function(BigInt eventId, bool liked, BigInt likedCount)? onLikeChanged;

  @override
  State<_FeedDetailPage> createState() => _FeedDetailPageState();
}

class _FeedDetailPageState extends State<_FeedDetailPage> {
  late bool _liked = widget.event.liked;
  late BigInt _likedCount = widget.event.likedCount;
  bool _likeBusy = false;

  Future<void> _toggleLike() async {
    final threadId = widget.event.threadId;
    if (threadId.isEmpty) {
      _snack('这条动态不支持点赞');
      return;
    }
    if (_likeBusy) return;
    _likeBusy = true;
    final target = !_liked;
    final before = _likedCount;
    setState(() {
      _liked = target;
      _likedCount = target ? _likedCount + BigInt.one : _likedCount - BigInt.one;
      if (_likedCount < BigInt.zero) _likedCount = BigInt.zero;
    });
    try {
      await rust.likeEvent(threadId: threadId, liked: target);
      widget.onLikeChanged?.call(widget.event.id, target, _likedCount);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _liked = !target;
        _likedCount = before;
      });
      _snack('点赞失败: ${friendlyError(e)}');
    } finally {
      _likeBusy = false;
    }
  }

  Future<void> _forward() async {
    final message = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('转发动态'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: '说点什么(可留空)'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('转发'),
            ),
          ],
        );
      },
    );
    if (message == null) return;
    try {
      final ok = await rust.forwardEvent(
        eventId: widget.event.id,
        userId: widget.event.userId,
        msg: message,
      );
      if (!mounted) return;
      _snack(ok ? '已转发' : '转发未生效');
    } catch (e) {
      if (!mounted) return;
      _snack('转发失败: ${friendlyError(e)}');
    }
  }

  Future<void> _copyLink() async {
    final link = 'https://music.163.com/#/event?id=${widget.event.id}';
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) _snack('链接已复制');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final event = widget.event;
    final hasThread = event.threadId.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('动态')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          Row(
            children: [
              CircleCover(url: event.avatarUrl, size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.userName.isEmpty ? '网易云用户' : event.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      '${feedRelativeTime(event.timeMs)} · '
                      '${feedKindLabels[event.kind] ?? '动态'}',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.outline),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (event.title.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              event.title.trim(),
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
          if (event.text.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              event.text.trim(),
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          ],
          if (event.images.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ImageGrid(urls: event.images),
          ],
          if (event.videoUrl != null) ...[
            const SizedBox(height: 12),
            AspectRatio(
              aspectRatio: 16 / 9,
              child: GestureDetector(
                onTap: () => widget.onOpenUrl(event.videoUrl!),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NetImage(
                      url: event.coverUrl ?? (event.images.isNotEmpty ? event.images.first : null),
                      width: double.infinity,
                      height: double.infinity,
                      icon: Icons.videocam_outlined,
                    ),
                    const ColoredBox(color: Colors.black26),
                    const Center(
                      child: Icon(Icons.play_circle_fill, color: Colors.white, size: 56),
                    ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => widget.onOpenUrl(event.videoUrl!),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('用系统播放器打开视频'),
              ),
            ),
          ],
          if (event.song != null) ...[
            const SizedBox(height: 12),
            _SongCard(
              song: event.song!,
              onPlay: () => widget.onPlaySongs([event.song!], 0),
            ),
          ],
          const SizedBox(height: 8),
          const Divider(),
          Row(
            children: [
              TextButton.icon(
                onPressed: _toggleLike,
                icon: Icon(
                  _liked ? Icons.favorite : Icons.favorite_border,
                  size: 18,
                  color: _liked ? scheme.primary : null,
                ),
                label: Text('${_likedCount > BigInt.zero ? _likedCount : ''}'),
              ),
              TextButton.icon(
                onPressed: hasThread
                    ? () => Navigator.of(context).pop()
                    : null,
                icon: const Icon(Icons.mode_comment_outlined, size: 18),
                label: Text('${event.commentCount > BigInt.zero ? event.commentCount : '评论'}'),
              ),
              TextButton.icon(
                onPressed: _forward,
                icon: const Icon(Icons.autorenew, size: 18),
                label: Text('${event.shareCount > BigInt.zero ? event.shareCount : ''}'),
              ),
              const Spacer(),
              IconButton(
                tooltip: '复制链接',
                onPressed: _copyLink,
                icon: const Icon(Icons.link, size: 18),
              ),
            ],
          ),
          const Divider(),
          if (hasThread)
            _EventComments(threadId: event.threadId, totalHint: event.commentCount.toInt())
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '这条动态暂不支持评论',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// 配图网格: 1 张放大铺满, 多张按 3 列平铺(与官方动态一致的 9 宫格)
class _ImageGrid extends StatelessWidget {
  const _ImageGrid({required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    if (urls.length == 1) {
      return GestureDetector(
        onTap: () => showImageViewer(context, urls: urls),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: NetImage(url: urls.first, width: double.infinity, radius: 8),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 6.0;
        const columns = 3;
        final size = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (var i = 0; i < urls.length; i++)
              GestureDetector(
                onTap: () => showImageViewer(context, urls: urls, initialIndex: i),
                child: NetImage(url: urls[i], width: size, height: size, radius: 6),
              ),
          ],
        );
      },
    );
  }
}

class _SongCard extends StatelessWidget {
  const _SongCard({required this.song, required this.onPlay});

  final rust.SongDto song;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: song.playable ? onPlay : null,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            CoverArt(url: song.coverUrl, size: 48),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.play_arrow,
              color: song.playable ? scheme.primary : scheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}

/// 动态评论区(threadId 维度, 与歌曲/歌单评论区分开)
class _EventComments extends StatefulWidget {
  const _EventComments({required this.threadId, this.totalHint = 0});

  final String threadId;
  final int totalHint;

  @override
  State<_EventComments> createState() => _EventCommentsState();
}

class _EventCommentsState extends State<_EventComments> {
  static const int _pageSize = 20;

  final List<rust.CommentDto> _items = <rust.CommentDto>[];
  BigInt _total = BigInt.zero;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await retryNetwork(
        () => rust.eventComments(
          threadId: widget.threadId,
          limit: _pageSize,
          offset: 0,
        ),
      );
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.comments);
        _total = page.total;
        _hasMore = page.hasMore;
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = await retryNetwork(
        () => rust.eventComments(
          threadId: widget.threadId,
          limit: _pageSize,
          offset: _items.length,
        ),
      );
      if (!mounted) return;
      setState(() {
        _items.addAll(page.comments);
        _total = page.total;
        _hasMore = page.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final count = _total > BigInt.zero ? _total : BigInt.from(widget.totalHint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '评论',
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
        ),
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
                  '评论加载失败: $_error',
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
        else ...[
          for (final c in _items) _EventCommentTile(comment: c),
          if (_hasMore)
            Center(
              child: _loadingMore
                  ? const Padding(
                      padding: EdgeInsets.all(8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : TextButton(onPressed: _loadMore, child: const Text('加载更多')),
            ),
        ],
      ],
    );
  }
}

class _EventCommentTile extends StatelessWidget {
  const _EventCommentTile({required this.comment});

  final rust.CommentDto comment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleCover(url: comment.avatarUrl, size: 28, icon: Icons.person_outline),
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
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      comment.liked ? Icons.favorite : Icons.favorite_border,
                      size: 12,
                      color: comment.liked ? scheme.primary : scheme.outline,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '${comment.likedCount}',
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(comment.content, style: theme.textTheme.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  feedRelativeTime(comment.timeMs),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
