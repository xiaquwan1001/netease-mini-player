import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'cover_art.dart'
    show CoverArt, fetchImageBytes, httpsImageUrl, showImageViewer;
import 'image_io.dart';
import 'net_retry.dart' show describeError;
import 'state_views.dart' show LoadingView;
import 'toast.dart';

/// 歌曲详情页(歌词页)的**两个面**。
enum DetailFace { lyrics, cover }

/// 详情页「歌词 ⇄ 封面」容器: 轻点画面在两面之间切换。
///
/// 为什么单独成一个控件(而不是写进 HomePage):
/// - 它只吃"当前曲目/节目的封面地址 + 一块歌词子树", 与歌词数据、播放器都无关;
///   播客单集播放时进队列的也是同一个 `SongDto`(见 `detail/podcast_detail_page.dart`
///   的 `_playProgram`), 所以**歌曲与播客共用这一份逻辑**, 没有第二套页面;
/// - 切面是纯展示态, 不写任何持久化设置: 每次进详情页 / 换曲都从歌词开始。
///
/// 手势口径(为什么点"歌词区"就等于切面):
/// - 歌词行的点击本来只在多选态才有语义(onLineTap 为 null 时不注册 tap),
///   非多选态的轻点此前什么都不做 —— 这里把它接成"切到封面";
/// - 拖动歌词是 Scrollable 自己的 drag 手势, 拖动成功后 tap 会被手势竞技场判负,
///   所以"滑动歌词"永远不会切面; 长按(多选)同理, 长按胜过轻点;
/// - 右下的翻译/定位按钮与封面面的两个按钮都在更深的层级, 自己的 tap 赢,
///   不会穿透到切面手势;
/// - 多选态由页面传 [tappable] = false 关掉切面手势(那层点击语义是"选中某句")。
///
/// 状态保留: 歌词面用 [Offstage] 常驻(与首页 `_buildTabPages` 同一手法),
/// 切到封面再切回来时滚动位置、多选、翻译开关都不丢; 播放中自动跟随在封面态
/// 仍然继续, 所以回到歌词时看到的是"当前正在唱的那句"(用户手动滑动过后仍按
/// 用户自己停下的位置)。
class DetailFaces extends StatefulWidget {
  const DetailFaces({
    super.key,
    required this.trackId,
    required this.coverUrl,
    required this.lyrics,
    this.tappable = true,
    this.saveImage,
    this.fetchImage,
  });

  /// 当前曲目/节目 id: **一变就回到歌词面**(换歌/换节目)
  final BigInt? trackId;

  /// 当前曲目/节目的封面地址; 空/取图失败时给中性占位, 不留白屏
  final String? coverUrl;

  /// 歌词面(页面自己构建, 这里只负责显隐)
  final Widget lyrics;

  /// 是否允许"轻点画面切面"。多选歌词时页面传 false。
  final bool tappable;

  /// 保存实现(测试注入假实现, 不落盘); null = 走 [saveImageBytes]
  final Future<String> Function(Uint8List bytes, String filename)? saveImage;

  /// 取原图字节实现(测试注入假实现, 不联网); null = 走 [fetchImageBytes]
  final Future<Uint8List> Function(String url)? fetchImage;

  @override
  State<DetailFaces> createState() => _DetailFacesState();
}

/// 封面四周留白(方图不贴边)
const double _kCoverInset = 16;

class _DetailFacesState extends State<DetailFaces> {
  DetailFace _face = DetailFace.lyrics;
  bool _saving = false;

  @override
  void didUpdateWidget(covariant DetailFaces oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换歌/换节目 -> 回到歌词: 封面是"看这张图"的一次性动作, 不是常驻页;
    // 否则听下一首时详情页会突然变成一张不认识的图。
    if (oldWidget.trackId != widget.trackId) {
      _face = DetailFace.lyrics;
      _saving = false;
    }
  }

  void _toggleFace() {
    if (!widget.tappable) return;
    setState(() {
      _face = _face == DetailFace.cover ? DetailFace.lyrics : DetailFace.cover;
    });
  }

  String get _cover => httpsImageUrl(widget.coverUrl);

  Future<void> _save() async {
    if (_saving || _cover.isEmpty) return;
    setState(() => _saving = true);
    try {
      final bytes = await (widget.fetchImage ?? fetchImageBytes)(_cover);
      final save = widget.saveImage ?? saveImageBytes;
      final where = await save(bytes, _filename(_cover));
      if (!mounted) return;
      showToast(context, '封面已保存: $where');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '保存失败: ${describeError(e)}', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 查看原图 = 复用全屏看图(可缩放 + 右上角"保存原图"), 不另写一份预览
  void _openViewer() {
    if (_cover.isEmpty) return;
    unawaited(
      showImageViewer(
        context,
        urls: [_cover],
        saveOverride: widget.saveImage,
        fetchOverride: widget.fetchImage,
      ),
    );
  }

  /// 保存文件名: 扩展名从 URL 猜(网易云 CDN 基本是 .jpg), 前缀带时间戳防重名
  String _filename(String url) {
    final path = Uri.tryParse(url)?.path ?? '';
    final m = RegExp(
      r'\.(jpe?g|png|webp|gif)$',
      caseSensitive: false,
    ).firstMatch(path);
    final ext = (m?.group(1) ?? 'jpg').toLowerCase();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    return 'MiniNCM_cover_$stamp.$ext';
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // 歌词面: Offstage 常驻 —— 切走不销毁, 滚动位置/多选/翻译态都留着
        Positioned.fill(
          child: Offstage(
            offstage: _face == DetailFace.cover,
            child: GestureDetector(
              key: const ValueKey('detail-lyrics-face'),
              behavior: HitTestBehavior.opaque,
              onTap: widget.tappable ? _toggleFace : null,
              child: widget.lyrics,
            ),
          ),
        ),
        if (_face == DetailFace.cover)
          Positioned.fill(child: _buildCoverFace(context)),
      ],
    );
  }

  Widget _buildCoverFace(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cover = _cover;
    return GestureDetector(
      key: const ValueKey('detail-cover-face'),
      // 再点一次回歌词(画面任意处); 按钮在更深的层级, 自己的 tap 赢
      behavior: HitTestBehavior.opaque,
      onTap: _toggleFace,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 尽量方形: 取可用空间的短边 —— 方图不裁边, 长边留白
          final side = math.max(
            0.0,
            math.min(constraints.maxWidth, constraints.maxHeight) -
                _kCoverInset * 2,
          );
          return Stack(
            children: [
              Center(
                child: side <= 0
                    ? const SizedBox.shrink()
                    : (cover.isEmpty
                          ? _buildPlaceholder(context, side)
                          : CoverArt(url: cover, size: side, radius: 12)),
              ),
              Positioned(
                left: _kCoverInset,
                right: _kCoverInset,
                bottom: _kCoverInset,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '轻点画面返回歌词',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (cover.isNotEmpty) ...[
                      IconButton.filledTonal(
                        key: const ValueKey('detail-cover-save'),
                        tooltip: '保存封面',
                        icon: _saving
                            ? const LoadingView.inline(size: 20)
                            : const Icon(Icons.download, size: 20),
                        onPressed: _saving ? null : _save,
                      ),
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        key: const ValueKey('detail-cover-view'),
                        tooltip: '查看原图',
                        icon: const Icon(Icons.zoom_out_map, size: 20),
                        onPressed: _openViewer,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 无封面/取图失败的中性占位: 不留白屏, 也不假装有一张图
  Widget _buildPlaceholder(BuildContext context, double side) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      key: const ValueKey('detail-cover-placeholder'),
      width: side,
      height: side,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      // FittedBox: 极小视口(或超大字号)下整体缩, 不溢出
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.music_note, size: 40, color: scheme.outline),
                const SizedBox(height: 8),
                Text(
                  '暂无封面',
                  maxLines: 1,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
