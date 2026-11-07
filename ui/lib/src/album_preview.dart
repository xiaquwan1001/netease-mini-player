import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';

typedef AlbumLoader = Future<rust.AlbumDetailDto> Function(BigInt albumId);

/// 专辑封面预览: 大图 + 专辑信息 + 曲目列表.
/// 点曲目 → 关闭预览, 用整张专辑重置播放队列并从这首开始.
/// loadAlbum 可注入(测试用), 默认走 Rust 接口.
Future<void> showAlbumPreview(
  BuildContext context, {
  required BigInt albumId,
  String? albumName,
  String? coverUrl,
  required void Function(List<rust.SongDto> songs, int index) onPlay,
  AlbumLoader? loadAlbum,
  /// 从"收藏的专辑"进来时已知已收藏, 直接显示"已收藏"
  bool initiallySubscribed = false,
  /// 测试注入: 收藏/取消收藏
  Future<bool> Function(BigInt albumId, bool subscribed)? setSubscribed,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _AlbumPreviewDialog(
      albumId: albumId,
      albumName: albumName,
      coverUrl: coverUrl,
      onPlay: onPlay,
      load: loadAlbum ?? (id) => rust.albumDetail(albumId: id),
      initiallySubscribed: initiallySubscribed,
      setSubscribed: setSubscribed ??
          (id, subscribed) => rust.setAlbumSubscribed(
                albumId: id,
                subscribed: subscribed,
              ),
    ),
  );
}

class _AlbumPreviewDialog extends StatefulWidget {
  const _AlbumPreviewDialog({
    required this.albumId,
    required this.albumName,
    required this.coverUrl,
    required this.onPlay,
    required this.load,
    required this.initiallySubscribed,
    required this.setSubscribed,
  });

  final BigInt albumId;
  final String? albumName;
  final String? coverUrl;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final AlbumLoader load;
  final bool initiallySubscribed;
  final Future<bool> Function(BigInt albumId, bool subscribed) setSubscribed;

  @override
  State<_AlbumPreviewDialog> createState() => _AlbumPreviewDialogState();
}

class _AlbumPreviewDialogState extends State<_AlbumPreviewDialog> {
  rust.AlbumDetailDto? _album;
  String? _error;
  bool _loading = false;

  /// 收藏状态: 由入参决定初值, 点按钮后本地翻转(没有可靠的"是否已收藏"查询接口)
  late bool _subscribed = widget.initiallySubscribed;
  bool _subBusy = false;
  String? _subError;

  @override
  void initState() {
    super.initState();
    if (widget.albumId > BigInt.zero) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final album = await retryNetwork(() => widget.load(widget.albumId));
      if (!mounted) return;
      setState(() => _album = album);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggleSubscribe() async {
    final target = !_subscribed;
    setState(() {
      _subBusy = true;
      _subError = null;
    });
    try {
      final ok = await widget.setSubscribed(widget.albumId, target);
      if (!mounted) return;
      setState(() => _subscribed = ok ? target : _subscribed);
    } catch (e) {
      if (!mounted) return;
      setState(() => _subError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _subBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final album = _album;
    final name = album?.name ?? widget.albumName ?? '专辑';
    final cover = album?.coverUrl ?? widget.coverUrl;
    final songs = album?.songs ?? const <rust.SongDto>[];
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CoverArt(url: cover, size: 120, radius: 10),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: Theme.of(context).textTheme.titleMedium,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            album?.artist ?? '未知歌手',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          if (songs.isNotEmpty)
                            Text(
                              '共 ${songs.length} 首',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (album != null && album.description.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              album.description,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
                if (widget.albumId > BigInt.zero)
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: _subBusy ? null : _toggleSubscribe,
                        icon: Icon(
                          _subscribed ? Icons.favorite : Icons.favorite_border,
                          size: 18,
                          color: _subscribed
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        label: Text(_subscribed ? '已收藏' : '收藏专辑'),
                      ),
                      if (_subBusy)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      if (_subError != null)
                        Expanded(
                          child: Text(
                            _subError!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '专辑加载失败: $_error',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                        TextButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  ),
                if (album != null && songs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: Text('这张专辑暂无曲目, 先去听听别的吧')),
                  ),
                if (songs.isNotEmpty)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: songs.length,
                      itemBuilder: (context, i) {
                        final s = songs[i];
                        return ListTile(
                          dense: true,
                          leading: Text('${i + 1}'),
                          title: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: s.playable
                                ? null
                                : TextStyle(
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                          ),
                          subtitle: Text(
                            s.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          enabled: s.playable,
                          trailing: SongOverflowButton(song: s, size: 20),
                          onTap: s.playable
                              ? () {
                                  Navigator.pop(context);
                                  widget.onPlay(songs, i);
                                }
                              : null,
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('关闭'),
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
