import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 关注动态流: 未登录引导 + 登录后的 RefreshIndicator 列表。
/// 每条是 FeedEventDto(单曲/歌单/专辑/节目/文字动态), 不做评论/点赞。
class FeedView extends StatefulWidget {
  const FeedView({
    super.key,
    required this.loggedIn,
    required this.onLogin,
    required this.onPlaySongs, // void Function(List<rust.SongDto>, int)
    required this.onOpenUrl, // Future<void> Function(String url) —— 视频交给系统打开
    this.onOpenArtist, // 预留
    this.loadFeed, // 测试注入
  });

  final bool loggedIn;
  final VoidCallback onLogin;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;
  final void Function(BigInt artistId)? onOpenArtist;
  final Future<List<rust.FeedEventDto>> Function()? loadFeed;

  @override
  State<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<FeedView> {
  List<rust.FeedEventDto>? _events;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.loggedIn) _load();
  }

  @override
  void didUpdateWidget(covariant FeedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 登录态从无到有时再拉一次
    if (widget.loggedIn &&
        !oldWidget.loggedIn &&
        _events == null &&
        _error == null) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final load =
          widget.loadFeed ?? () => rust.feedEvents(limit: 30, lastTime: -1);
      final events = await retryNetwork(load);
      if (!mounted) return;
      setState(() => _events = events);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (!widget.loggedIn) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.rss_feed_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text('登录后查看关注的艺人/好友动态', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
            FilledButton(onPressed: widget.onLogin, child: const Text('登录')),
          ],
        ),
      );
    }
    if (_events == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final events = _events!;
    return RefreshIndicator(
      onRefresh: _load,
      child: events.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 64),
                  child: Center(
                    child: Text('还没有动态', style: theme.textTheme.bodySmall),
                  ),
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemCount: events.length,
              itemBuilder: (context, i) => _FeedCard(
                event: events[i],
                onPlaySongs: widget.onPlaySongs,
                onOpenUrl: widget.onOpenUrl,
              ),
            ),
    );
  }
}

/// 一条动态卡片
class _FeedCard extends StatelessWidget {
  const _FeedCard({
    required this.event,
    required this.onPlaySongs,
    required this.onOpenUrl,
  });

  final rust.FeedEventDto event;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;

  static const _kindLabels = {
    'song': '单曲',
    'playlist': '歌单',
    'album': '专辑',
    'program': '节目',
    'text': '动态',
    'other': '动态',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 头部: 头像 + 用户名 + kind 标签 + 相对时间
            Row(
              children: [
                CircleCover(url: event.avatarUrl, size: 40),
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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _kindLabels[event.kind] ?? '动态',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _relativeTime(event.timeMs),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            // 正文(最多 3 行)
            if (event.text.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  event.text.trim(),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            // 单曲 mini 卡
            if (event.song != null)
              _MiniSongCard(
                song: event.song!,
                coverUrl: event.coverUrl,
                onPlaySongs: onPlaySongs,
              ),
            // 配图(最多 3 张)
            if (event.images.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < event.images.length && i < 3; i++)
                    Padding(
                      padding: EdgeInsets.only(right: i == 2 ? 0 : 8),
                      child: GestureDetector(
                        onTap: () => showImageViewer(
                          context,
                          urls: event.images,
                          initialIndex: i,
                        ),
                        child: NetImage(
                          url: event.images[i],
                          width: 64,
                          height: 64,
                          radius: 6,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            // 视频: 16:9 封面 + 播放圆标 + 右上角标签, 点击交给系统打开
            if (event.videoUrl != null) ...[
              const SizedBox(height: 8),
              _VideoThumb(
                url: event.videoUrl!,
                coverUrl: event.coverUrl,
                onOpenUrl: onOpenUrl,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 单曲 mini 卡: CoverArt + 歌名/歌手 + play 图标, 点击播放这一首
class _MiniSongCard extends StatelessWidget {
  const _MiniSongCard({
    required this.song,
    required this.coverUrl,
    required this.onPlaySongs,
  });

  final rust.SongDto song;
  final String? coverUrl;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: song.playable ? () => onPlaySongs([song], 0) : null,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              CoverArt(url: song.coverUrl ?? coverUrl, size: 40),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      song.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: song.playable ? null : scheme.outline,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.play_arrow,
                size: 24,
                color: song.playable ? scheme.primary : scheme.outline,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 16:9 视频封面: NetImage(coverUrl 兜底) + 居中白色播放圆标 + 右上角"视频"标签
class _VideoThumb extends StatelessWidget {
  const _VideoThumb({
    required this.url,
    required this.coverUrl,
    required this.onOpenUrl,
  });

  final String url;
  final String? coverUrl;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: GestureDetector(
        onTap: () => onOpenUrl(url),
        child: Stack(
          fit: StackFit.expand,
          children: [
            NetImage(
              url: coverUrl,
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              icon: Icons.videocam_outlined,
            ),
            // 半透明暗化, 突出播放按钮
            const ColoredBox(color: Colors.black26),
            Center(
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  color: Colors.white54,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.play_arrow,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '视频',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 相对时间: 刚刚/分钟前/小时前/天前/日期, 与 detail_page 同一套格式
String _relativeTime(BigInt timeMs) {
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
