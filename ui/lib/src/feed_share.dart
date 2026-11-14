import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'cover_art.dart';
import 'feed_detail_page.dart' show feedRelativeTime;
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'song_share.dart' show SongShare, capturePng;
import 'toast.dart' show showToast, showToastWith;

/// 动态 / 评论的分享卡片与分享面板.
///
/// 与歌曲分享(`song_share.dart`)同一套模式:
/// - 卡片是普通 widget, 面板里先预览, 再由 RepaintBoundary 截图导出 PNG
///   (预览与导出像素一致, 不维护第二套排版);
/// - 平台差异只在 `SongShare.shareImage / saveImage`(Android 走自建 `ncm/share`
///   通道, 桌面落盘到 ~/Pictures/MiniNCM), 这里不碰平台插件;
/// - 「添加应用水印」开关默认关: 打开后卡片右下角画一行「轻音 MiniNCM」,
///   因为它在截图边界内, 导出的 PNG 里自然带上, 不需要二次合成。

/// 转发动态的 FFI 形态(默认 `rust.forwardEvent`; 列表/详情页传入注入版以便测试)
typedef FeedForwardHook = Future<bool> Function({
  required BigInt eventId,
  required BigInt userId,
  required String msg,
});

/// 动态卡片二维码内容(官方网页, 任何扫码器都能打开)
String feedShareUrl(BigInt eventId) =>
    'https://music.163.com/#/event?id=${eventId.toString()}';

/// 「复制评论」写进剪贴板的文本: 作者 + 正文 + 出处(可空)
String commentShareText({
  required String author,
  required String content,
  String sourceTitle = '',
  String sourceKindLabel = '动态',
}) {
  final who = author.trim().isEmpty ? '网易云用户' : author.trim();
  final body = '$who：${content.trim()}';
  final source = sourceTitle.trim();
  final kind = sourceKindLabel.trim().isEmpty ? '动态' : sourceKindLabel.trim();
  return source.isEmpty ? body : '$body\n—— 来自$kind《$source》';
}

/// 把标题里的非法文件名字符替换掉, 统一 `.png` 后缀
String sharePngFilename(String base) {
  final safe = base.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
  return '${safe.isEmpty ? 'share' : safe}.png';
}

const Color _cardBg = Color(0xFF15171C);
const Color _cardFg = Color(0xFFF3F4F6);
const Color _cardMuted = Color(0xFF9AA0AC);
const Color _cardAccent = Color(0xFFEC4141);

/// 卡片右下角的品牌水印文本(测试与截图共用同一份文案)
const String kShareWatermarkText = '轻音 MiniNCM';

/// 分享卡片(动态): 作者头像/昵称 + 正文或单曲/配图 + 时间 + 可选二维码 + 可选水印.
class FeedShareCard extends StatelessWidget {
  const FeedShareCard({
    super.key,
    required this.event,
    this.width = 340,
    this.showQr = true,
    this.watermark = false,
  });

  final rust.FeedEventDto event;
  final double width;

  /// 是否画二维码(官方网页直链); 关掉后卡片更矮, 适合只当"图片备份"
  final bool showQr;

  /// 是否在右下角画「轻音 MiniNCM」水印(画进截图)
  final bool watermark;

  @override
  Widget build(BuildContext context) {
    final text = event.text.trim();
    final title = event.title.trim();
    final song = event.song;
    final cover = (event.images.isNotEmpty ? event.images.first : null);
    return Container(
      width: width,
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleCover(url: event.avatarUrl, size: 36),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.userName.isEmpty ? '网易云用户' : event.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _cardFg,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (feedRelativeTime(event.timeMs).isNotEmpty)
                      Text(
                        feedRelativeTime(event.timeMs),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _cardMuted, fontSize: 11),
                      ),
                  ],
                ),
              ),
            ],
          ),
          if (title.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _cardFg,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                height: 1.3,
              ),
            ),
          ],
          if (text.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              text,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: _cardFg, fontSize: 13, height: 1.6),
            ),
          ],
          if (song != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2129),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  CoverArt(
                    url: song.coverUrl ?? event.coverUrl,
                    size: 44,
                    radius: 8,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _cardFg,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _cardMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else if (cover != null) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: NetImage(
                url: cover,
                width: double.infinity,
                height: 140,
                radius: 10,
                icon: Icons.image_outlined,
              ),
            ),
          ],
          if (showQr) ...[
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '扫码看这条动态',
                        style: TextStyle(
                          color: _cardFg,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '网易云音乐',
                        style: TextStyle(color: _cardMuted, fontSize: 11),
                      ),
                    ],
                  ),
                ),
                // 二维码必须落在浅底上, 否则暗色卡片里扫不出来
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.all(Radius.circular(8)),
                  ),
                  child: QrImageView(
                    data: feedShareUrl(event.id),
                    version: QrVersions.auto,
                    size: 76,
                    gapless: true,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF101114),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF101114),
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (watermark) ...[
            const SizedBox(height: 8),
            // 右下角品牌水印: 在截图边界内, 导出的 PNG 自带
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                kShareWatermarkText,
                style: TextStyle(
                  color: _cardAccent.withValues(alpha: 0.85),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 分享卡片(评论): 作者头像/昵称 + 评论正文 + 原动态标题(作为出处)
class CommentShareCard extends StatelessWidget {
  const CommentShareCard({
    super.key,
    required this.comment,
    this.sourceTitle = '',
    this.sourceKindLabel = '动态',
    this.width = 340,
    this.watermark = false,
  });

  final rust.Comment comment;

  /// 原动态标题/正文摘要(卡片底部"来自...《...》")
  final String sourceTitle;

  /// 出处类型词(歌曲/歌单/专辑/播客/动态), 决定"来自 X《标题》"里的 X
  final String sourceKindLabel;
  final double width;
  final bool watermark;

  @override
  Widget build(BuildContext context) {
    final source = sourceTitle.trim();
    final kind = sourceKindLabel.trim().isEmpty ? '动态' : sourceKindLabel.trim();
    return Container(
      width: width,
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleCover(url: comment.avatarUrl, size: 32),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  comment.userName.isEmpty ? '匿名用户' : comment.userName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _cardFg,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            comment.content.trim(),
            maxLines: 8,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: _cardFg, fontSize: 14, height: 1.6),
          ),
          // 互动数据(需求: 补上语境 —— 点赞/回复量随卡片一起导出)
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(
                comment.liked ? Icons.favorite : Icons.favorite_border,
                size: 13,
                color: comment.liked ? _cardAccent : _cardMuted,
              ),
              const SizedBox(width: 4),
              Text(
                '${comment.likedCount}',
                style: const TextStyle(color: _cardMuted, fontSize: 11),
              ),
              const SizedBox(
                width: 12,
              ), // token-ok: 卡片内部统计行同组间距, 12 是 layout.dart 允许集合
              const Icon(
                Icons.mode_comment_outlined,
                size: 13,
                color: _cardMuted,
              ),
              const SizedBox(width: 4),
              Text(
                '${comment.replyCount}',
                style: const TextStyle(color: _cardMuted, fontSize: 11),
              ),
            ],
          ),
          if (source.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2129),
                borderRadius: BorderRadius.circular(10),
                border: const Border(
                  left: BorderSide(color: _cardAccent, width: 3),
                ),
              ),
              child: Text(
                '来自$kind《$source》',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _cardMuted, fontSize: 11),
              ),
            ),
          ],
          if (watermark) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                kShareWatermarkText,
                style: TextStyle(
                  color: _cardAccent.withValues(alpha: 0.85),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 面板公共骨架: 标题 + 预览卡片(截图边界) + 开关 + 动作按钮.
class _ShareSheetFrame extends StatelessWidget {
  const _ShareSheetFrame({
    required this.title,
    required this.boundary,
    required this.cardBuilder,
    this.middle = const [],
    this.toggles = const [],
    required this.primaryActions,
    this.secondaryActions = const [],
  });

  final String title;
  final GlobalKey boundary;

  /// 按面板可用宽度构建卡片(窄屏按面板宽缩, 宽屏封顶 340)
  final Widget Function(double width) cardBuilder;

  /// 卡片与开关之间的内容(转发面板的转发语输入框)
  final List<Widget> middle;
  final List<Widget> toggles;
  final List<Widget> primaryActions;
  final List<Widget> secondaryActions;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(title: title),
            Flexible(
              child: SingleChildScrollView(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth.isFinite
                        ? (constraints.maxWidth - 4).clamp(240.0, 340.0)
                        : 340.0;
                    return Center(
                      child: RepaintBoundary(
                        key: boundary,
                        child: cardBuilder(width),
                      ),
                    );
                  },
                ),
              ),
            ),
            ...middle,
            ...toggles,
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < primaryActions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: primaryActions[i]),
                ],
              ],
            ),
            if (secondaryActions.isNotEmpty)
              Wrap(alignment: WrapAlignment.center, children: secondaryActions),
          ],
        ),
      ),
    );
  }
}

/// 分享面板(动态): 预览 + 水印/二维码开关 + 系统分享/保存图片/复制链接/转发动态.
Future<void> showFeedShareSheet(
  BuildContext context, {
  required rust.FeedEventDto event,
  FeedForwardHook? forwardEvent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FeedShareSheet(event: event, forwardEvent: forwardEvent),
  );
}

/// 转发面板(动态): 原动态预览 + 转发语(可空) + 水印/保存图片/复制链接/转发.
Future<void> showFeedForwardSheet(
  BuildContext context, {
  required rust.FeedEventDto event,
  FeedForwardHook? forwardEvent,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => FeedForwardSheet(event: event, forwardEvent: forwardEvent),
  );
}

/// 分享面板(评论): 评论卡片预览 + 保存图片/分享/复制评论.
Future<void> showCommentShareSheet(
  BuildContext context, {
  required rust.Comment comment,
  String sourceTitle = '',
  String sourceKindLabel = '动态',
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => CommentShareSheet(
      comment: comment,
      sourceTitle: sourceTitle,
      sourceKindLabel: sourceKindLabel,
    ),
  );
}

/// 分享面板(动态). 公开是为了让测试能直接按类型定位.
class FeedShareSheet extends StatefulWidget {
  const FeedShareSheet({super.key, required this.event, this.forwardEvent});

  final rust.FeedEventDto event;
  final FeedForwardHook? forwardEvent;

  @override
  State<FeedShareSheet> createState() => _FeedShareSheetState();
}

class _FeedShareSheetState extends State<FeedShareSheet> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;
  bool _watermark = false;
  bool _showQr = true;

  String get _filename =>
      sharePngFilename('动态-${widget.event.userName}-${widget.event.id}');

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final msg = await action();
      if (messenger != null) showToastWith(messenger, msg);
    } catch (e) {
      if (messenger != null) {
        showToastWith(messenger, '分享失败: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String> _shareImage() async {
    final png = await capturePng(_boundary, pixelRatio: 2);
    if (png == null) return '生成图片失败';
    return SongShare.shareImage(
      png,
      filename: _filename,
      text: widget.event.text.trim(),
    );
  }

  Future<String> _saveImage() async {
    final png = await capturePng(_boundary, pixelRatio: 2);
    if (png == null) return '生成图片失败';
    final path = await SongShare.saveImage(png, filename: _filename);
    return '已保存到 $path';
  }

  void _copyLink() {
    Clipboard.setData(ClipboardData(text: feedShareUrl(widget.event.id)));
    showToast(context, '链接已复制');
  }

  @override
  Widget build(BuildContext context) {
    return _ShareSheetFrame(
      title: '分享动态',
      boundary: _boundary,
      cardBuilder: (width) => FeedShareCard(
        event: widget.event,
        width: width,
        showQr: _showQr,
        watermark: _watermark,
      ),
      toggles: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('添加应用水印'),
          value: _watermark,
          onChanged: (v) => setState(() => _watermark = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('包含二维码'),
          value: _showQr,
          onChanged: (v) => setState(() => _showQr = v),
        ),
      ],
      primaryActions: [
        FilledButton.icon(
          onPressed: _busy ? null : () => _run(_shareImage),
          icon: const Icon(Icons.share),
          label: const Text('分享'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _run(_saveImage),
          icon: const Icon(Icons.download_outlined),
          label: const Text('保存图片'),
        ),
      ],
      secondaryActions: [
        TextButton.icon(
          onPressed: _copyLink,
          icon: const Icon(Icons.link, size: 18),
          label: const Text('复制链接'),
        ),
        TextButton.icon(
          onPressed: () {
            Navigator.of(context).pop();
            showFeedForwardSheet(
              context,
              event: widget.event,
              forwardEvent: widget.forwardEvent,
            );
          },
          icon: const Icon(Icons.autorenew, size: 18),
          label: const Text('转发动态'),
        ),
      ],
    );
  }
}

/// 转发面板(动态). 公开是为了让测试能直接按类型定位.
class FeedForwardSheet extends StatefulWidget {
  const FeedForwardSheet({super.key, required this.event, this.forwardEvent});

  final rust.FeedEventDto event;
  final FeedForwardHook? forwardEvent;

  @override
  State<FeedForwardSheet> createState() => _FeedForwardSheetState();
}

class _FeedForwardSheetState extends State<FeedForwardSheet> {
  final GlobalKey _boundary = GlobalKey();
  final TextEditingController _controller = TextEditingController();
  bool _busy = false;
  bool _watermark = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _filename =>
      sharePngFilename('转发-${widget.event.userName}-${widget.event.id}');

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forward() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.maybeOf(context);
    final navigator = Navigator.of(context);
    try {
      final forward = widget.forwardEvent ?? rust.forwardEvent;
      // 转发语允许为空(纯转发)
      final ok = await forward(
        eventId: widget.event.id,
        userId: widget.event.userId,
        msg: _controller.text.trim(),
      );
      if (!mounted) return;
      navigator.pop();
      if (messenger != null) {
        showToastWith(messenger, ok ? '已转发' : '转发未生效');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '转发失败: $e');
      if (messenger != null) {
        showToastWith(messenger, '转发失败: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _shareImage() async {
    // messenger 在 await 之前取: 截图是异步的, 之后 context 可能已失效
    final messenger = ScaffoldMessenger.maybeOf(context);
    final png = await capturePng(_boundary, pixelRatio: 2);
    if (png == null) return;
    final msg = await SongShare.shareImage(
      png,
      filename: _filename,
      text: _controller.text.trim(),
    );
    if (messenger != null) showToastWith(messenger, msg);
  }

  Future<void> _saveImage() async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final png = await capturePng(_boundary, pixelRatio: 2);
    if (png == null) return;
    final path = await SongShare.saveImage(png, filename: _filename);
    if (messenger != null) showToastWith(messenger, '已保存到 $path');
  }

  void _copyLink() {
    Clipboard.setData(ClipboardData(text: feedShareUrl(widget.event.id)));
    showToast(context, '链接已复制');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _ShareSheetFrame(
      title: '转发动态',
      boundary: _boundary,
      cardBuilder: (width) => FeedShareCard(
        event: widget.event,
        width: width,
        showQr: false,
        watermark: _watermark,
      ),
      middle: [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: TextField(
            controller: _controller,
            maxLines: 3,
            maxLength: 140,
            enabled: !_busy,
            decoration: const InputDecoration(
              hintText: '说点什么(可留空)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        if (_error != null)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
            ),
          ),
      ],
      toggles: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('添加应用水印'),
          value: _watermark,
          onChanged: (v) => setState(() => _watermark = v),
        ),
      ],
      primaryActions: [
        FilledButton.icon(
          onPressed: _busy ? null : _forward,
          icon: const Icon(Icons.autorenew),
          label: const Text('转发'),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _guard(_saveImage),
          icon: const Icon(Icons.download_outlined),
          label: const Text('保存图片'),
        ),
      ],
      secondaryActions: [
        TextButton.icon(
          onPressed: _copyLink,
          icon: const Icon(Icons.link, size: 18),
          label: const Text('复制链接'),
        ),
        TextButton.icon(
          onPressed: _busy ? null : () => _guard(_shareImage),
          icon: const Icon(Icons.share, size: 18),
          label: const Text('系统分享'),
        ),
      ],
    );
  }
}

/// 分享面板(评论). 公开是为了让测试能直接按类型定位.
class CommentShareSheet extends StatefulWidget {
  const CommentShareSheet({
    super.key,
    required this.comment,
    this.sourceTitle = '',
    this.sourceKindLabel = '动态',
  });

  final rust.Comment comment;
  final String sourceTitle;

  /// 出处类型词(歌曲/歌单/专辑/播客/动态)
  final String sourceKindLabel;

  @override
  State<CommentShareSheet> createState() => _CommentShareSheetState();
}

class _CommentShareSheetState extends State<CommentShareSheet> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;
  bool _watermark = false;

  String get _filename =>
      sharePngFilename('评论-${widget.comment.userName}-${widget.comment.id}');

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final msg = await action();
      if (messenger != null) showToastWith(messenger, msg);
    } catch (e) {
      if (messenger != null) {
        showToastWith(messenger, '分享失败: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copyComment() {
    Clipboard.setData(
      ClipboardData(
        text: commentShareText(
          author: widget.comment.userName,
          content: widget.comment.content,
          sourceTitle: widget.sourceTitle,
          sourceKindLabel: widget.sourceKindLabel,
        ),
      ),
    );
    showToast(context, '评论已复制');
  }

  @override
  Widget build(BuildContext context) {
    return _ShareSheetFrame(
      title: '分享评论',
      boundary: _boundary,
      cardBuilder: (width) => CommentShareCard(
        comment: widget.comment,
        sourceTitle: widget.sourceTitle,
        sourceKindLabel: widget.sourceKindLabel,
        width: width,
        watermark: _watermark,
      ),
      toggles: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('添加应用水印'),
          value: _watermark,
          onChanged: (v) => setState(() => _watermark = v),
        ),
      ],
      primaryActions: [
        FilledButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final png = await capturePng(_boundary, pixelRatio: 2);
                  if (png == null) return '生成图片失败';
                  return SongShare.shareImage(
                    png,
                    filename: _filename,
                    text: widget.comment.content,
                  );
                }),
          icon: const Icon(Icons.share),
          label: const Text('分享'),
        ),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() async {
                  final png = await capturePng(_boundary, pixelRatio: 2);
                  if (png == null) return '生成图片失败';
                  final path = await SongShare.saveImage(
                    png,
                    filename: _filename,
                  );
                  return '已保存到 $path';
                }),
          icon: const Icon(Icons.download_outlined),
          label: const Text('保存图片'),
        ),
      ],
      secondaryActions: [
        TextButton.icon(
          onPressed: _copyComment,
          icon: const Icon(Icons.content_copy, size: 18),
          label: const Text('复制评论'),
        ),
      ],
    );
  }
}
