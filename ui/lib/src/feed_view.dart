import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'feed_detail_page.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 关注动态流: 未登录引导 + 登录后的动态列表.
///
/// 顶部是一行"艺人分类"(全部 + 本页出现过的发布者), 默认按时间顺序(接口顺序)
/// 展示全部动态, 选中某个艺人只看 ta 的动态; 卡片点进去是详情页
/// (完整正文 / 配图 / 视频 / 单曲卡 / 点赞转发 / 评论区)。
class FeedView extends StatefulWidget {
  const FeedView({
    super.key,
    required this.loggedIn,
    required this.onLogin,
    required this.onPlaySongs, // void Function(List<rust.SongDto>, int)
    required this.onOpenUrl, // Future<void> Function(String url) —— 视频交给系统打开
    this.loadFeed, // 测试注入
  });

  final bool loggedIn;
  final VoidCallback onLogin;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;
  final Future<List<rust.FeedEventDto>> Function()? loadFeed;

  @override
  State<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<FeedView> {
  List<rust.FeedEventDto>? _events;
  String? _error;

  /// 当前选中的艺人(按 userId 过滤), null = 全部
  BigInt? _authorFilter;

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
      setState(() {
        _events = events;
        // 选中的艺人还在本页就保留, 否则回到"全部"
        if (_authorFilter != null &&
            !events.any((e) => e.userId == _authorFilter)) {
          _authorFilter = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  /// 本页出现过的发布者(按首次出现顺序 = 最近的时间顺序), 供分类行使用
  List<_Author> get _authors {
    final seen = <BigInt>{};
    final out = <_Author>[];
    for (final e in _events ?? const <rust.FeedEventDto>[]) {
      final key = e.userId != BigInt.zero ? e.userId : BigInt.from(-e.id.toInt());
      if (!seen.add(key)) continue;
      out.add(_Author(
        userId: e.userId,
        name: e.userName.isEmpty ? '网易云用户' : e.userName,
        avatarUrl: e.avatarUrl,
      ));
    }
    return out;
  }

  List<rust.FeedEventDto> get _visible {
    final all = _events ?? const <rust.FeedEventDto>[];
    final filter = _authorFilter;
    if (filter == null) return all;
    return [for (final e in all) if (e.userId == filter) e];
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
    final events = _visible;
    return Column(
      children: [
        _ArtistFilterBar(
          authors: _authors,
          selected: _authorFilter,
          onSelected: (id) => setState(() => _authorFilter = id),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: events.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 64),
                        child: Center(
                          child: Text(
                            _authorFilter == null ? '还没有动态' : 'ta 最近没有动态',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    itemCount: events.length,
                    itemBuilder: (context, i) => _FeedCard(
                      event: events[i],
                      onPlaySongs: widget.onPlaySongs,
                      onOpenUrl: widget.onOpenUrl,
                      onOpenChanged: _replace,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  /// 详情页点赞回来后同步列表里的状态
  void _replace(rust.FeedEventDto updated) {
    final list = _events;
    if (list == null) return;
    final index = list.indexWhere((e) => e.id == updated.id);
    if (index < 0) return;
    setState(() => list[index] = updated);
  }
}

class _Author {
  const _Author({required this.userId, required this.name, this.avatarUrl});

  final BigInt userId;
  final String name;
  final String? avatarUrl;
}

/// 横向艺人分类: "全部" + 本页出现的发布者(头像 + 昵称)
class _ArtistFilterBar extends StatelessWidget {
  const _ArtistFilterBar({
    required this.authors,
    required this.selected,
    required this.onSelected,
  });

  final List<_Author> authors;
  final BigInt? selected;
  final void Function(BigInt? userId) onSelected;

  @override
  Widget build(BuildContext context) {
    if (authors.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 84,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        children: [
          _AuthorChip(
            label: '全部',
            avatarUrl: null,
            icon: Icons.all_inclusive,
            selected: selected == null,
            onTap: () => onSelected(null),
            scheme: scheme,
          ),
          for (final a in authors)
            _AuthorChip(
              label: a.name,
              avatarUrl: a.avatarUrl,
              selected: selected == a.userId,
              onTap: () => onSelected(a.userId),
              scheme: scheme,
            ),
        ],
      ),
    );
  }
}

class _AuthorChip extends StatelessWidget {
  const _AuthorChip({
    required this.label,
    required this.avatarUrl,
    required this.selected,
    required this.onTap,
    required this.scheme,
    this.icon,
  });

  final String label;
  final String? avatarUrl;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          width: 64,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    width: 2,
                    color: selected ? scheme.primary : Colors.transparent,
                  ),
                ),
                child: icon != null
                    ? CircleAvatar(
                        radius: 20,
                        backgroundColor: selected
                            ? scheme.primaryContainer
                            : scheme.surfaceContainerHighest,
                        child: Icon(icon, size: 20, color: scheme.primary),
                      )
                    : CircleCover(url: avatarUrl, size: 40),
              ),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 一条动态卡片(摘要; 点整卡进详情页)
class _FeedCard extends StatelessWidget {
  const _FeedCard({
    required this.event,
    required this.onPlaySongs,
    required this.onOpenUrl,
    required this.onOpenChanged,
  });

  final rust.FeedEventDto event;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;
  final void Function(rust.FeedEventDto updated) onOpenChanged;

  Future<void> _openDetail(BuildContext context) async {
    await showFeedDetail(
      context,
      event: event,
      onPlaySongs: onPlaySongs,
      onOpenUrl: onOpenUrl,
      onLikeChanged: (id, liked, likedCount) => onOpenChanged(
        rust.FeedEventDto(
          id: event.id,
          threadId: event.threadId,
          userId: event.userId,
          kind: event.kind,
          userName: event.userName,
          avatarUrl: event.avatarUrl,
          text: event.text,
          song: event.song,
          coverUrl: event.coverUrl,
          images: event.images,
          videoUrl: event.videoUrl,
          title: event.title,
          timeMs: event.timeMs,
          liked: liked,
          likedCount: likedCount,
          shareCount: event.shareCount,
          commentCount: event.commentCount,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasBody = event.text.trim().isNotEmpty ||
        event.title.trim().isNotEmpty ||
        event.song != null ||
        event.images.isNotEmpty ||
        event.videoUrl != null;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(context),
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
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      feedKindLabels[event.kind] ?? '动态',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    feedRelativeTime(event.timeMs),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
              // 正文(最多 4 行, 详情页看全文)
              if (event.text.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    event.text.trim(),
                    maxLines: 4,
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
              // 配图(最多 3 张预览)
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
              if (hasBody) ...[
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      event.liked ? Icons.favorite : Icons.favorite_border,
                      size: 14,
                      color: event.liked ? scheme.primary : scheme.outline,
                    ),
                    if (event.likedCount > BigInt.zero) ...[
                      const SizedBox(width: 4),
                      Text(
                        '${event.likedCount}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                    const SizedBox(width: 14),
                    Icon(Icons.mode_comment_outlined,
                        size: 14, color: scheme.outline),
                    if (event.commentCount > BigInt.zero) ...[
                      const SizedBox(width: 4),
                      Text(
                        '${event.commentCount}',
                        style: theme.textTheme.labelSmall
                            ?.copyWith(color: scheme.outline),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      '查看详情',
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.outline),
                    ),
                    Icon(Icons.chevron_right, size: 16, color: scheme.outline),
                  ],
                ),
              ],
            ],
          ),
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
