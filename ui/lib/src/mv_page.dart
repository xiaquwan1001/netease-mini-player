import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'format.dart' show formatDurationMs;
import 'mv_playback.dart';
import 'error_views.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// MV 详情/播放页(C3): 封面大图 + 标题/歌手/播放量/发布时间/简介 + 播放按钮。
/// Android 内嵌 VideoView(独立 Activity, 不进歌曲队列); 桌面无视频能力,
/// 按钮为「用系统播放器打开」。打开方式: [showMvPage]。
Future<void> showMvPage(
  BuildContext context, {
  required BigInt mvId,
  String? name,
  MvPlayback? playback,
  Future<rust.MvDetailDto> Function(BigInt)? loadDetail,
  Future<rust.MvUrlDto> Function(BigInt, int r)? loadUrl,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MvPage(
        mvId: mvId,
        name: name,
        playback: playback ?? MvPlayback(),
        loadDetail: loadDetail,
        loadUrl: loadUrl,
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
  });

  final BigInt mvId;
  final String? name;
  final MvPlayback playback;
  final Future<rust.MvDetailDto> Function(BigInt)? loadDetail;
  final Future<rust.MvUrlDto> Function(BigInt, int r)? loadUrl;

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
      body: FutureBuilder<rust.MvDetailDto>(
        future: _loadDetail(widget.mvId),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return FullError(
              message: friendlyError(snap.error!),
              onRetry: () => setState(() {}), // FutureBuilder 重新取数
            );
          }
          final d = snap.data!;
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
              Text(d.name, style: theme.textTheme.titleLarge),
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
            ],
          );
        },
      ),
    );
  }
}
