import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'cover_art.dart';
import 'image_io.dart';
import 'rust/api.dart' as rust;
import 'sheet_header.dart';
import 'toast.dart';

/// 歌曲分享: 生成一张带封面 + 歌词 + 二维码的分享卡片, 再交给系统分享/保存.
///
/// 设计的几个硬约束:
/// - **不引平台插件**: Android 走自建 `ncm/share` 通道(FileProvider + ACTION_SEND),
///   Linux 直接落盘到 ~/Pictures/MiniNCM(桌面没有系统分享面板, 落盘即"分享").
/// - 卡片是普通 Flutter widget, 在面板里**先给用户预览**, 再用 RepaintBoundary
///   截图导出 PNG —— 预览与导出的像素一致, 不维护第二套排版代码.
/// - 二维码指向官方网页(https://music.163.com/song?id=...) —— 扫码即达,
///   不依赖本 App 的深链 scheme.

/// 分享卡片里的二维码内容(官方网页, 任何扫码器都能打开)
String songShareUrl(BigInt trackId) =>
    'https://music.163.com/song?id=${trackId.toString()}';

/// 卡片标题行里的一行歌词: 去掉首尾空白, 空行丢弃
List<String> shareableLyricLines(Iterable<String> lines, {int max = 6}) {
  final out = <String>[];
  for (final raw in lines) {
    final t = raw.trim();
    if (t.isEmpty || t == '♪') continue;
    out.add(t);
    if (out.length >= max) break;
  }
  return out;
}

/// 平台分享桥. Android: `ncm/share` 通道; 其它平台: 写文件.
///
/// 「保存字节到图库/图片目录」已抽到 [saveImageBytes](见 `image_io.dart`),
/// 因为看大图的"保存原图"也要用, 而 `song_share.dart` 依赖 `cover_art.dart`(反向依赖会成环).
class SongShare {
  static const MethodChannel _channel = MethodChannel('ncm/share');

  static bool get _android => !kIsWeb && Platform.isAndroid;

  /// 把 PNG 交给系统分享面板. 返回给用户看的提示文案.
  static Future<String> shareImage(
    Uint8List png, {
    required String filename,
    String text = '',
  }) async {
    if (_android) {
      await _channel.invokeMethod<bool>('shareImage', {
        'bytes': png,
        'filename': filename,
        'text': text,
      });
      return '已打开系统分享';
    }
    final path = await saveImage(png, filename: filename);
    return '已保存到 $path';
  }

  /// 保存 PNG. Android 落系统图库(MiniNCM/), 桌面落 ~/Pictures/MiniNCM.
  /// 返回保存位置(给提示文案用).
  static Future<String> saveImage(Uint8List png, {required String filename}) =>
      saveImageBytes(png, filename: filename);
}

/// 把 [boundaryKey] 对应的 RepaintBoundary 导出成 PNG 字节.
///
/// 调用前必须已经完成一帧布局和绘制(面板里预览过就满足); 未挂载/未绘制时返回 null.
Future<Uint8List?> capturePng(
  GlobalKey boundaryKey, {
  double pixelRatio = 2,
}) async {
  final object = boundaryKey.currentContext?.findRenderObject();
  if (object is! RenderRepaintBoundary) return null;
  // 卡片可能被预览容器缩小过, 用 2x 采样保证文字清晰
  final image = await object.toImage(pixelRatio: pixelRatio);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// 分享卡片(纯展示, 不含交互): 封面 + 曲名/艺人 + 可选歌词 + 二维码.
///
/// 尺寸固定 [width] x 自适应高度, 由外层 RepaintBoundary 截图.
class SongShareCard extends StatelessWidget {
  const SongShareCard({
    super.key,
    required this.song,
    this.lyricLines = const [],
    this.width = 340,
  });

  final rust.SongDto song;

  /// 选中的歌词(最多 6 行, 调用方已过滤空行)
  final List<String> lyricLines;
  final double width;

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF15171C);
    const fg = Color(0xFFF3F4F6);
    const muted = Color(0xFF9AA0AC);
    const accent = Color(0xFFEC4141);
    return Container(
      width: width,
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.all(Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CoverArt(url: song.coverUrl, size: 88, radius: 12),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: fg,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        height: 1.25,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                    if (song.album.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '《${song.album}》',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: muted, fontSize: 11),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (lyricLines.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1E2129),
                borderRadius: BorderRadius.circular(12),
                border: const Border(left: BorderSide(color: accent, width: 3)),
              ),
              child: Text(
                lyricLines.join('\n'),
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: fg, fontSize: 13, height: 1.6),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '扫码听这首歌',
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text('网易云音乐', style: TextStyle(color: muted, fontSize: 11)),
                    const SizedBox(height: 10),
                    Text(
                      '轻音 MiniNCM',
                      style: TextStyle(
                        color: accent.withValues(alpha: 0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
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
                  data: songShareUrl(song.id),
                  version: QrVersions.auto,
                  size: 84,
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
      ),
    );
  }
}

/// 分享面板: 预览卡片 → 分享 / 保存 / 复制链接.
Future<void> showSongShareSheet(
  BuildContext context, {
  required rust.SongDto song,
  List<String> lyricLines = const [],
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) =>
        _SongShareSheet(song: song, lyricLines: lyricLines),
  );
}

class _SongShareSheet extends StatefulWidget {
  const _SongShareSheet({required this.song, required this.lyricLines});

  final rust.SongDto song;
  final List<String> lyricLines;

  @override
  State<_SongShareSheet> createState() => _SongShareSheetState();
}

class _SongShareSheetState extends State<_SongShareSheet> {
  final GlobalKey _boundary = GlobalKey();
  bool _busy = false;

  String get _filename {
    String safe(String s) => s.replaceAll(RegExp(r'[/\:*?"<>|]'), '_').trim();
    final base = '${safe(widget.song.artist)} - ${safe(widget.song.name)}';
    return '${base.isEmpty ? 'song' : base}.png';
  }

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

  Future<Uint8List?> _png() => capturePng(_boundary, pixelRatio: 2);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(title: '分享歌曲'),
            Flexible(
              child: SingleChildScrollView(
                // 卡片宽度跟着面板走: 300dp 窄屏上按面板宽缩, 宽屏封顶 340
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth.isFinite
                        ? (constraints.maxWidth - 4).clamp(240.0, 340.0)
                        : 340.0;
                    return Center(
                      child: RepaintBoundary(
                        key: _boundary,
                        child: SongShareCard(
                          song: widget.song,
                          lyricLines: widget.lyricLines,
                          width: width,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final png = await _png();
                            if (png == null) return '生成图片失败';
                            return SongShare.shareImage(
                              png,
                              filename: _filename,
                              text:
                                  '${widget.song.artist} - ${widget.song.name}',
                            );
                          }),
                    icon: const Icon(Icons.share),
                    label: const Text('分享'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            final png = await _png();
                            if (png == null) return '生成图片失败';
                            final path = await SongShare.saveImage(
                              png,
                              filename: _filename,
                            );
                            return '已保存到 $path';
                          }),
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('保存'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () {
                Clipboard.setData(
                  ClipboardData(text: songShareUrl(widget.song.id)),
                );
                showToast(context, '已复制分享链接');
              },
              icon: const Icon(Icons.link, size: 18),
              label: const Text('复制链接'),
            ),
          ],
        ),
      ),
    );
  }
}
