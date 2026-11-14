import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'async_view.dart';
import 'comment_thread.dart';
import 'cover_art.dart';
import 'error_views.dart' show FullError;
import 'layout.dart' show kSectionGap;
import 'net_retry.dart' show friendlyError;
import 'state_views.dart' show LoadingView;
import 'format.dart' show formatDurationMs;
import 'mv_playback.dart';
import 'rust/api.dart' as rust;

/// MV 详情/播放页(C3): 封面大图 + 标题/艺人/播放量/发布时间/简介 + 播放按钮
/// + **评论区**(需求 10: 看评论 / 发评论 / 点赞)。
/// Android 内嵌 VideoView(独立 Activity, 不进歌曲队列); 桌面无视频能力,
/// 按钮为「用系统播放器打开」(评论区与平台无关, 桌面同样可用)。打开方式: [showMvPage]。
Future<void> showMvPage(
  BuildContext context, {
  required BigInt mvId,
  String? name,
  MvPlayback? playback,
  Future<rust.MvDetailDto> Function(BigInt)? loadDetail,
  Future<rust.MvUrlDto> Function(BigInt, int r)? loadUrl,
  Future<rust.CommentPage> Function(int limit, int offset)? loadComments,
  Future<bool> Function(BigInt commentId, bool liked)? likeComment,
  Future<bool> Function(BigInt commentId, String content)? replyComment,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MvPage(
        mvId: mvId,
        name: name,
        playback: playback ?? MvPlayback(),
        loadDetail: loadDetail,
        loadUrl: loadUrl,
        loadComments: loadComments,
        likeComment: likeComment,
        replyComment: replyComment,
      ),
    ),
  );
}

class MvPage extends StatefulWidget {
  const MvPage({
    super.key,
    required this.mvId,
    required this.playback,
    this.name,
    this.loadDetail,
    this.loadUrl,
    this.loadComments,
    this.likeComment,
    this.replyComment,
  });

  final BigInt mvId;
  final String? name;
  final MvPlayback playback;
  final Future<rust.MvDetailDto> Function(BigInt)? loadDetail;
  final Future<rust.MvUrlDto> Function(BigInt, int r)? loadUrl;

  /// MV 评论列表(测试注入)。缺省走 rust.comments(kind: 'mv') →
  /// provider 的 comment_mv, threadId 形如 R_MV_5_数字, 与歌曲评论同形。
  final Future<rust.CommentPage> Function(int limit, int offset)? loadComments;

  /// 评论点赞(MV 评论区同形复用; 缺省走 rust.likeComment)
  final Future<bool> Function(BigInt commentId, bool liked)? likeComment;

  /// 发表评论/回复(缺省走 rust.replyComment, commentId=0 即顶层评论)
  final Future<bool> Function(BigInt commentId, String content)? replyComment;

  @override
  State<MvPage> createState() => _MvPageState();
}

class _MvPageState extends State<MvPage> {
  bool _starting = false;
  String? _startError;
  rust.MvDetailDto? _detail;

  Future<rust.MvDetailDto> _loadDetail(BigInt id) =>
      widget.loadDetail?.call(id) ?? rust.mvDetail(mvId: id);

  Future<rust.MvUrlDto> _loadUrl(BigInt id, int r) =>
      widget.loadUrl?.call(id, r) ?? rust.mvUrl(mvId: id, r: r);

  /// 内嵌播放能力由 MvPlayback 决定(Android=true), 测试可注入
  bool get _android => widget.playback.supportsInlinePlayback;

  /// http 直链转 https(已验证签名直链 https 可用; Android 默认禁 cleartext)
  static String _toHttps(String url) =>
      url.startsWith('http://') ? 'https://${url.substring(7)}' : url;

  Future<void> _startPlayback() async {
    if (_starting) return;
    setState(() {
      _starting = true;
      _startError = null;
    });
    try {
      final u = await _loadUrl(widget.mvId, 0);
      final url = u.url;
      if (url == null || url.isEmpty) {
        throw Exception('该 MV 无可播放链接(可能需要 VIP 或已下架)');
      }
      await widget.playback.play(
        _toHttps(url),
        _detail?.name ?? widget.name ?? 'MV',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _startError = '播放失败: $e\n(直链约 1 小时过期, 可返回重进重试)');
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.name ?? 'MV')),
      body: AsyncView<rust.MvDetailDto>(
        // 收敛: 四态(加载/错误/空/数据)统一到 async_view.dart, 原来这里手写
        // FutureBuilder; 重试与首载现在走同一条 load(内部套 retryNetwork)。
        load: () => _loadDetail(widget.mvId),
        emptyText: '没有取到 MV 详情',
        // 整页错误/加载视觉沿用改前: 全尺寸 LoadingView + 居中 FullError,
        // 而不是区块级的行内四态(MV 页整页只有这一块内容)。
        loadingBuilder: (_) => const LoadingView(),
        errorBuilder: (_, error, retry) =>
            FullError(message: friendlyError(error), onRetry: retry),
        builder: (context, d, reload) {
          _detail = d;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (d.coverUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: NetImage(url: d.coverUrl, fit: BoxFit.cover),
                ),
              const SizedBox(height: 16),
              // MV 名允许两行(长标题一行放不下时不再硬截断)
              AdaptiveText(
                d.name,
                mode: AdaptiveTextMode.wrap,
                maxLines: 2,
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                [
                  if (d.artistName.isNotEmpty) d.artistName,
                  '播放 ${d.playCount}',
                  if (d.publishTime.isNotEmpty) d.publishTime,
                  formatDurationMs(d.durationMs),
                  if (d.maxBr > 0) '最高 ${d.maxBr}P',
                ].join(' · '),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if ((d.desc ?? '').isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(d.desc!, style: theme.textTheme.bodyMedium),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _starting ? null : _startPlayback,
                icon: Icon(
                  _android ? Icons.play_circle_fill : Icons.open_in_new,
                ),
                label: Text(
                  _starting
                      ? '正在取链…'
                      : _android
                      ? '播放'
                      : '用系统播放器打开(桌面无内嵌视频)',
                ),
              ),
              if (!_android) ...[
                const SizedBox(height: 8),
                Text(
                  '桌面端没有内嵌视频播放能力, 将用系统默认播放器/浏览器打开 MV 直链。',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_startError != null) ...[
                const SizedBox(height: 12),
                Text(
                  _startError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: kSectionGap),
              const Divider(height: 1),
              // MV 评论区(需求 10): 看评论/发评论/点赞全部复用 CommentThread,
              // kind 'mv' 走 provider 的 comment_mv(/R_MV_5_<id>), 与歌曲评论同形,
              // 点赞/回复仍用第一页返回的 threadId, 不需要新增 FFI。
              // inset 0: 页面本身已有 16dp 边距, 评论区不再加一层(与动态详情同一口径)。
              CommentThread(
                kind: 'mv',
                resourceId: widget.mvId,
                inset: EdgeInsets.zero,
                loadPage: widget.loadComments,
                like: widget.likeComment,
                reply: widget.replyComment,
              ),
            ],
          );
        },
      ),
    );
  }
}
