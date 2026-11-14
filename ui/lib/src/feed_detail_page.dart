import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'comment_thread.dart';
import 'cover_art.dart';
import 'feed_media.dart';
import 'feed_share.dart';
import 'format.dart' show formatDateYmd;
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_tile.dart' show SongTitleWithBadges;
import 'toast.dart' show showToast;
import 'user_nav.dart';

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

  /// true = 打开后直接滚到评论区(列表页点"评论"数字进来)。
  /// 只滚动定位, 不自动弹写评论面板 —— 用户点的是"看评论";
  /// 想要"滚过去 + 聚焦输入框"仍走页面内评论按钮(focusComposer)。
  bool focusComments = false,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _FeedDetailPage(
        event: event,
        onPlaySongs: onPlaySongs,
        onOpenUrl: onOpenUrl,
        onLikeChanged: onLikeChanged,
        focusComments: focusComments,
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
  // 超过 30 天退回日期, 统一走 format.dart 的 yyyy-MM-dd 口径
  return formatDateYmd(timeMs);
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
    this.focusComments = false,
  });

  final rust.FeedEventDto event;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;
  final void Function(BigInt eventId, bool liked, BigInt likedCount)?
  onLikeChanged;

  /// 打开后直接滚到评论区(列表页"评论"入口), 不弹写评论面板
  final bool focusComments;

  @override
  State<_FeedDetailPage> createState() => _FeedDetailPageState();
}

class _FeedDetailPageState extends State<_FeedDetailPage> {
  late bool _liked = widget.event.liked;
  late BigInt _likedCount = widget.event.likedCount;
  bool _likeBusy = false;

  /// 评论区句柄: 「评论」按钮经它触发聚焦输入框(见 CommentThread.focusComposer)
  final GlobalKey<CommentThreadState> _commentThreadKey =
      GlobalKey<CommentThreadState>();

  /// 评论区锚点: focusComments 进来时经它把评论区滚进视口(不弹输入框)
  final GlobalKey _commentsAnchorKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    if (widget.focusComments && widget.event.threadId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealComments());
    }
  }

  /// 把评论区顶部对齐到视口顶(直达到位, 不做"最小可见"滚动)。
  /// 不用 Scrollable.ensureVisible: 它只保证目标可见(尾对齐视口尾),
  /// 用户语义是"看评论区", 应该让评论区从顶部开始。
  void _revealComments() {
    if (!mounted) return;
    final anchor = _commentsAnchorKey.currentContext;
    if (anchor == null) return;
    final renderObject = anchor.findRenderObject();
    if (renderObject is! RenderBox) return;
    final viewport = RenderAbstractViewport.maybeOf(renderObject);
    final position = Scrollable.maybeOf(anchor)?.position;
    if (viewport == null ||
        position == null ||
        !position.hasContentDimensions) {
      return;
    }
    final target = viewport
        .getOffsetToReveal(renderObject, 0.0)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    position.jumpTo(target);
  }

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
      _likedCount = target
          ? _likedCount + BigInt.one
          : _likedCount - BigInt.one;
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

  /// 转发: 独立转发面板(原动态预览 + 转发语可空 + 水印/保存图片/复制链接/转发)。
  /// 原先只是个 AlertDialog, 转发界面本身缺失。
  Future<void> _forward() {
    return showFeedForwardSheet(context, event: widget.event);
  }

  Future<void> _copyLink() async {
    final link = 'https://music.163.com/#/event?id=${widget.event.id}';
    await Clipboard.setData(ClipboardData(text: link));
    if (mounted) _snack('链接已复制');
  }

  void _snack(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final event = widget.event;
    final hasThread = event.threadId.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('动态')),
      // SingleChildScrollView(非懒构建): 内容节点固定且少, 且"定位到评论区"
      // 依赖评论区锚点常在树上 —— 懒构建的 ListView 会让视口外锚点拿不到
      // context(focusComments 直达失效), 这里必须全量构建。
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                UserAvatarTap(
                  userId: event.userId,
                  nickname: event.userName,
                  child: CircleCover(url: event.avatarUrl, size: 40),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        event.userName.isEmpty ? '网易云用户' : event.userName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${feedRelativeTime(event.timeMs)} · '
                        '${feedKindLabels[event.kind] ?? '动态'}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.outline,
                        ),
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
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
            if (event.text.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              SelectableText(
                event.text.trim(),
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ],
            // 配图: 与列表卡片同一份排版(1 张大图 / 2 两列 / 3+ 三列),
            // 且只放用户自己附的照片(分享单曲的动态不再重复附带专辑封面)
            if (feedAttachedImages(event).isNotEmpty) ...[
              const SizedBox(height: 12),
              FeedImageGrid(images: feedAttachedImages(event)),
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
                        url:
                            event.coverUrl ??
                            (event.images.isNotEmpty
                                ? event.images.first
                                : null),
                        width: double.infinity,
                        height: double.infinity,
                        icon: Icons.videocam_outlined,
                      ),
                      const ColoredBox(color: Colors.black26),
                      const Center(
                        child: Icon(
                          Icons.play_circle_fill,
                          color: Colors.white,
                          size: 56,
                        ),
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
                  label: Text(
                    '${_likedCount > BigInt.zero ? _likedCount : ''}',
                  ),
                ),
                TextButton.icon(
                  onPressed: hasThread
                      ? () => _commentThreadKey.currentState?.focusComposer()
                      : null,
                  icon: const Icon(Icons.mode_comment_outlined, size: 18),
                  label: Text(
                    '${event.commentCount > BigInt.zero ? event.commentCount : '评论'}',
                  ),
                ),
                TextButton.icon(
                  onPressed: _forward,
                  icon: const Icon(Icons.autorenew, size: 18),
                  label: Text(
                    '${event.shareCount > BigInt.zero ? event.shareCount : ''}',
                  ),
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
              KeyedSubtree(
                key: _commentsAnchorKey,
                child: CommentThread(
                  key: _commentThreadKey,
                  threadId: event.threadId,
                  totalHint: event.commentCount.toInt(),
                  // 评论分享卡片上的"来自动态《...》": 标题优先, 没有就用正文摘要
                  shareSourceTitle: event.title.trim().isNotEmpty
                      ? event.title.trim()
                      : event.text.trim(),
                  // 页面本身已有 16dp 左右边距, 评论区不再自己加 12dp,
                  // 让每条评论与正文左对齐(用户反馈行首空白).
                  inset: const EdgeInsets.fromLTRB(0, 16, 0, 8),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('这条动态暂不支持评论', style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
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
                  SongTitleWithBadges(
                    song: song,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall
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
