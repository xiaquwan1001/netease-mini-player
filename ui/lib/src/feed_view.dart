import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cover_art.dart';
import 'feed_detail_page.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'toast.dart' show showToast;
import 'user_nav.dart';
import 'sheet_header.dart';

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
    this.loadSubscribedArtists, // 测试注入(关注艺人, 用于"全部艺人"面板)
    this.likeEvent, // 测试注入(列表行点赞, 默认 rust.likeEvent)
    this.forwardEvent, // 测试注入(列表行转发, 默认 rust.forwardEvent)
  });

  final bool loggedIn;
  final VoidCallback onLogin;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;
  final Future<List<rust.FeedEventDto>> Function()? loadFeed;
  final Future<List<rust.Artist>> Function()? loadSubscribedArtists;

  /// 列表行"点赞"动作: 直接走 FFI(不必进详情页), 失败在列表上提示并回滚
  final Future<bool> Function({required String threadId, required bool liked})?
  likeEvent;

  /// 列表行"转发"动作(分享面板里选"转发动态"时用)
  final Future<bool> Function({
    required BigInt eventId,
    required BigInt userId,
    required String msg,
  })?
  forwardEvent;

  @override
  State<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<FeedView> {
  List<rust.FeedEventDto>? _events;
  String? _error;

  /// 正在列表行点赞中的动态 id(防抖: 同一条一次只允许一个在途请求)
  final Set<BigInt> _likeBusy = {};

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

  /// 本页出现过的发布者, 按"互动频率"从高到低(详见 [_Author.score]).
  /// 同分保持首次出现顺序(≈ 最近一次发动态的时间), 避免分类行顺序乱跳.
  List<_Author> get _authors {
    final byKey = <BigInt, _Author>{};
    var firstSeen = 0;
    for (final e in _events ?? const <rust.FeedEventDto>[]) {
      final key = e.userId != BigInt.zero
          ? e.userId
          : BigInt.from(-e.id.toInt());
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = _Author(
          userId: e.userId,
          name: e.userName.isEmpty ? '网易云用户' : e.userName,
          avatarUrl: e.avatarUrl,
          firstSeen: firstSeen++,
        ).addEvent(e);
      } else {
        byKey[key] = existing.addEvent(e);
      }
    }
    final out = byKey.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        return byScore != 0 ? byScore : a.firstSeen.compareTo(b.firstSeen);
      });
    return out;
  }

  /// 分类行只放互动频率最高的几个, 其余走"进入全部"
  static const _visibleAuthorCount = 8;

  /// 打开"全部艺人"面板: 本页发布者(按频率) + 关注但本页没发动态的艺人
  Future<void> _openAllArtists() async {
    final selected = await showModalBottomSheet<BigInt?>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AllArtistsSheet(
        authors: _authors,
        selected: _authorFilter,
        loadSubscribed:
            widget.loadSubscribedArtists ??
            () => rust.subscribedArtists(limit: 100),
      ),
    );
    // null = 用户取消(不动筛选); BigInt.zero = 面板里的"全部动态"(清筛选)
    if (selected == null || !mounted) return;
    setState(() => _authorFilter = selected == BigInt.zero ? null : selected);
  }

  List<rust.FeedEventDto> get _visible {
    final all = _events ?? const <rust.FeedEventDto>[];
    final filter = _authorFilter;
    if (filter == null) return all;
    return [
      for (final e in all)
        if (e.userId == filter) e,
    ];
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
    final authors = _authors;
    return Column(
      children: [
        _ArtistFilterBar(
          authors: authors.take(_visibleAuthorCount).toList(),
          totalAuthors: authors.length,
          selected: _authorFilter,
          onSelected: (id) => setState(() => _authorFilter = id),
          onOpenAll: _openAllArtists,
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
                      onLike: () => _toggleLike(events[i]),
                      forwardEvent: widget.forwardEvent,
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

  /// 列表行直接点赞: 乐观翻转(立即变色/变数), 失败回滚并提示
  Future<void> _toggleLike(rust.FeedEventDto event) async {
    if (event.threadId.isEmpty) {
      _snack('这条动态不支持点赞');
      return;
    }
    if (_likeBusy.contains(event.id)) return;
    _likeBusy.add(event.id);
    final target = !event.liked;
    final before = event.likedCount;
    var after = target ? before + BigInt.one : before - BigInt.one;
    if (after < BigInt.zero) after = BigInt.zero;
    _patchLike(event.id, liked: target, likedCount: after);
    try {
      final like = widget.likeEvent ?? rust.likeEvent;
      await like(threadId: event.threadId, liked: target);
    } catch (e) {
      if (!mounted) return;
      _patchLike(event.id, liked: !target, likedCount: before);
      _snack('点赞失败: ${friendlyError(e)}');
    } finally {
      _likeBusy.remove(event.id);
    }
  }

  void _patchLike(
    BigInt id, {
    required bool liked,
    required BigInt likedCount,
  }) {
    final list = _events;
    if (list == null) return;
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    setState(() {
      list[index] = _copyEventWith(
        list[index],
        liked: liked,
        likedCount: likedCount,
      );
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    showToast(context, message);
  }
}

/// 复制一条动态并替换点赞状态(列表行乐观更新 / 详情页点赞回传共用)
rust.FeedEventDto _copyEventWith(
  rust.FeedEventDto e, {
  required bool liked,
  required BigInt likedCount,
}) => rust.FeedEventDto(
  id: e.id,
  threadId: e.threadId,
  userId: e.userId,
  kind: e.kind,
  userName: e.userName,
  avatarUrl: e.avatarUrl,
  text: e.text,
  song: e.song,
  coverUrl: e.coverUrl,
  images: e.images,
  videoUrl: e.videoUrl,
  title: e.title,
  timeMs: e.timeMs,
  liked: liked,
  likedCount: likedCount,
  shareCount: e.shareCount,
  commentCount: e.commentCount,
);

class _Author {
  const _Author({
    required this.userId,
    required this.name,
    this.avatarUrl,
    this.firstSeen = 0,
    this.postCount = 0,
    this.likes = 0,
    this.comments = 0,
    this.shares = 0,
  });

  final BigInt userId;
  final String name;
  final String? avatarUrl;

  /// 在本页动态流里首次出现的位置(同分时的次序 + "全部艺人"里的展示顺序)
  final int firstSeen;

  /// 本页动态条数(≈ 发动态的频率)
  final int postCount;
  final int likes;
  final int comments;
  final int shares;

  /// "互动频率"分数: 发动态本身权重最高, 其次是被人点赞/评论/转发.
  /// 只统计当前这页动态(30 条窗口), 因此反映的是"最近谁最活跃/最被互动",
  /// 不是历史总量 —— 与"当前互动频率较高"的语义一致.
  int get score => postCount * 6 + likes + comments * 2 + shares * 2;

  _Author addEvent(rust.FeedEventDto e) => _Author(
    userId: userId,
    name: name,
    avatarUrl: avatarUrl ?? e.avatarUrl,
    firstSeen: firstSeen,
    postCount: postCount + 1,
    likes: likes + e.likedCount.toInt(),
    comments: comments + e.commentCount.toInt(),
    shares: shares + e.shareCount.toInt(),
  );

  /// "3 条动态 · 120 互动"
  String get subtitle {
    final interactions = likes + comments + shares;
    final parts = <String>['$postCount 条动态'];
    if (interactions > 0) parts.add('$interactions 互动');
    return parts.join(' · ');
  }
}

/// 横向艺人分类: "全部" + 互动频率最高的若干发布者 + 末尾"进入全部"入口
class _ArtistFilterBar extends StatelessWidget {
  const _ArtistFilterBar({
    required this.authors,
    required this.totalAuthors,
    required this.selected,
    required this.onSelected,
    required this.onOpenAll,
  });

  /// 已按互动频率排序, 且已截断到"高频率的几位"
  final List<_Author> authors;

  /// 本页发布者总数(> authors.length 时"进入全部"才有意义)
  final int totalAuthors;
  final BigInt? selected;
  final void Function(BigInt? userId) onSelected;
  final Future<void> Function() onOpenAll;

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
          // 末尾固定一个"进入全部": 浏览所有艺人(本页 + 已关注)
          _AuthorChip(
            label: totalAuthors > authors.length
                ? '进入全部($totalAuthors)'
                : '进入全部',
            avatarUrl: null,
            icon: Icons.grid_view,
            selected: false,
            onTap: onOpenAll,
            scheme: scheme,
            wide: true,
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
    this.wide = false,
  });

  final String label;
  final String? avatarUrl;
  final bool selected;
  final VoidCallback onTap;
  final ColorScheme scheme;
  final IconData? icon;

  /// "进入全部"这类文字较长的入口用更宽的格子
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          width: wide ? 84 : 64,
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
    required this.onLike,
    this.forwardEvent,
  });

  final rust.FeedEventDto event;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;
  final void Function(rust.FeedEventDto updated) onOpenChanged;

  /// 列表行点赞(乐观更新/回滚在 FeedView 的列表状态里做)
  final VoidCallback onLike;

  /// 转发动作(分享面板"转发动态"), 默认 rust.forwardEvent
  final Future<bool> Function({
    required BigInt eventId,
    required BigInt userId,
    required String msg,
  })?
  forwardEvent;

  /// 分享动作面板: 转发(带转发语, 走 forwardEvent) / 复制链接(剪贴板)。
  /// 与详情页同源(链接/文案一致), 只是入口在列表行上, 不必进详情页。
  Future<void> _openShareSheet(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SheetHeader(title: '分享'),
            ListTile(
              leading: const Icon(Icons.autorenew),
              title: const Text('转发动态'),
              onTap: () => Navigator.pop(sheetContext, 'forward'),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制链接'),
              onTap: () => Navigator.pop(sheetContext, 'copy'),
            ),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    if (action == 'copy') {
      await Clipboard.setData(
        ClipboardData(text: 'https://music.163.com/#/event?id=${event.id}'),
      );
      if (!context.mounted) return;
      _snack(context, '链接已复制');
      return;
    }
    // 转发: 与详情页一致, 先填转发语(可留空)
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
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('转发'),
            ),
          ],
        );
      },
    );
    if (message == null || !context.mounted) return;
    try {
      final forward = forwardEvent ?? rust.forwardEvent;
      final ok = await forward(
        eventId: event.id,
        userId: event.userId,
        msg: message,
      );
      if (!context.mounted) return;
      _snack(context, ok ? '已转发' : '转发未生效');
    } catch (e) {
      if (!context.mounted) return;
      _snack(context, '转发失败: ${friendlyError(e)}');
    }
  }

  void _snack(BuildContext context, String message) {
    showToast(context, message);
  }

  Future<void> _openDetail(
    BuildContext context, {
    bool focusComments = false,
  }) async {
    await showFeedDetail(
      context,
      event: event,
      onPlaySongs: onPlaySongs,
      onOpenUrl: onOpenUrl,
      // 从"评论"数字/图标进来时直接定位到评论区(不弹输入框)
      focusComments: focusComments,
      onLikeChanged: (id, liked, likedCount) => onOpenChanged(
        _copyEventWith(event, liked: liked, likedCount: likedCount),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasBody =
        event.text.trim().isNotEmpty ||
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
          // 页面 12 + 卡片 8 = 20dp/侧: 动态是正文流, 太宽会明显浪费横向空间
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 头部: 头像 + 用户名 + kind 标签 + 相对时间
              Row(
                children: [
                  UserAvatarTap(
                    userId: event.userId,
                    nickname: event.userName,
                    child: CircleCover(url: event.avatarUrl, size: 40),
                  ),
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
                  // 与用户名同列(头像 40 + 间距 10), 不再顶格错位
                  padding: const EdgeInsets.only(top: 8, left: 50),
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
                    // 点赞: 可点, 乐观翻转(变色/变数), 失败由 FeedView 回滚
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: onLike,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              event.liked
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              size: 14,
                              color: event.liked
                                  ? scheme.primary
                                  : scheme.outline,
                            ),
                            if (event.likedCount > BigInt.zero) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${event.likedCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: event.liked
                                      ? scheme.primary
                                      : scheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    // 评论: 点数字/图标进详情并直接滚到评论区
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _openDetail(context, focusComments: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.mode_comment_outlined,
                              size: 14,
                              color: scheme.outline,
                            ),
                            if (event.commentCount > BigInt.zero) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${event.commentCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 分享: 动作面板(转发 / 复制链接)
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _openShareSheet(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 2,
                          vertical: 4,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.autorenew,
                              size: 14,
                              color: scheme.outline,
                            ),
                            if (event.shareCount > BigInt.zero) ...[
                              const SizedBox(width: 4),
                              Text(
                                '${event.shareCount}',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: scheme.outline,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    // 空间紧张(300dp+1.25)时"查看详情"缩放让位, 不溢出
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '查看详情',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: scheme.outline,
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              size: 16,
                              color: scheme.outline,
                            ),
                          ],
                        ),
                      ),
                    ),
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

/// "进入全部": 本页发布者(按互动频率) + 已关注但本页没发动态的艺人.
/// 选中后把 userId 回传给 FeedView, 由它设置分类筛选.
class _AllArtistsSheet extends StatefulWidget {
  const _AllArtistsSheet({
    required this.authors,
    required this.selected,
    required this.loadSubscribed,
  });

  final List<_Author> authors;
  final BigInt? selected;
  final Future<List<rust.Artist>> Function() loadSubscribed;

  @override
  State<_AllArtistsSheet> createState() => _AllArtistsSheetState();
}

class _AllArtistsSheetState extends State<_AllArtistsSheet> {
  List<rust.Artist>? _subscribed;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await retryNetwork(widget.loadSubscribed);
      if (!mounted) return;
      setState(() => _subscribed = list);
    } catch (e) {
      if (!mounted) return;
      // 关注列表拉不到不算错: 本页发布者照样能选
      setState(() => _error = friendlyError(e));
    }
  }

  /// 已关注但本页没发过动态的艺人(按关注列表顺序)
  List<rust.Artist> get _others {
    final list = _subscribed ?? const <rust.Artist>[];
    if (list.isEmpty) return const [];
    final inFeed = {for (final a in widget.authors) a.userId};
    final seen = <BigInt>{};
    return [
      for (final a in list)
        if (!inFeed.contains(a.id) && seen.add(a.id)) a,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final others = _others;
    final height = MediaQuery.of(context).size.height * 0.75;
    return SizedBox(
      height: height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SheetHeader(
            title: '全部艺人',
            trailing: Text(
              '共 ${widget.authors.length + others.length} 位',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.outline,
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                // 点这一行 = 取消筛选, 回到全部动态
                ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.all_inclusive, size: 18),
                  ),
                  title: const Text('全部动态'),
                  subtitle: const Text('不按艺人筛选'),
                  trailing: widget.selected == null
                      ? Icon(Icons.check, color: scheme.primary)
                      : null,
                  onTap: () => Navigator.of(context).pop(BigInt.zero),
                ),
                const Divider(height: 1),
                if (widget.authors.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '本页动态 · 按互动频率排序',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ),
                for (final a in widget.authors)
                  ListTile(
                    leading: CircleCover(url: a.avatarUrl, size: 40),
                    title: Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(a.subtitle),
                    trailing: widget.selected == a.userId
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(a.userId),
                  ),
                if (_subscribed == null && _error == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (others.isNotEmpty) ...[
                  const Divider(height: 24),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                    child: Text(
                      '已关注 · 本页暂无动态',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
                    ),
                  ),
                  for (final a in others)
                    ListTile(
                      leading: CircleCover(url: a.avatarUrl, size: 40),
                      title: Text(
                        a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: const Text('暂无动态'),
                      trailing: widget.selected == a.id
                          ? Icon(Icons.check, color: scheme.primary)
                          : null,
                      onTap: () => Navigator.of(context).pop(a.id),
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
