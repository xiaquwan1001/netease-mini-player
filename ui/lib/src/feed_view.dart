import 'package:flutter/material.dart';

import 'artist_nav.dart';
import 'cover_art.dart';
import 'feed_share.dart';
import 'song_tile.dart' show SongTitleWithBadges;
import 'feed_detail_page.dart';
import 'layout.dart' show avatarStripHeightFor;
import 'net_retry.dart';
import 'rust/api.dart' as rust;
import 'toast.dart' show showToast;
import 'user_nav.dart';
import 'sheet_header.dart';
import 'state_views.dart';

/// 动态分页加载器: limit = 每页条数, lastTime = 上一页最后一条的 time_ms(unix 毫秒;
/// -1 表示"最新一页", 见 ncm-api 的 lasttime 语义)。
typedef FeedPageLoader = Future<List<rust.FeedEventDto>> Function({
  required int limit,
  required int lastTime,
});

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
    this.loadOlder, // 测试注入(滚动到底加载更早一页, 默认 rust.feedEvents)
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

  /// 更早一页的加载器: lastTime = 当前列表最后一条的 time_ms(unix 毫秒)。
  /// 不传就用现有 FFI 签名 rust.feedEvents(limit, lastTime) 当游标 ——
  /// 后端提供专门的分页游标后只需替换这一处。
  final FeedPageLoader? loadOlder;

  @override
  State<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<FeedView> {
  List<rust.FeedEventDto>? _events;
  String? _error;

  /// 每页条数(与后端约定一致)
  static const int _pageSize = 30;

  /// 是否还可能存在更早一页(上一页返回满页, 且确实有新条目)
  bool _hasMore = false;

  /// 后端给的分页游标(`FeedPageDto.lastTime`); null = 还没翻过页,
  /// 第一页之后的更早一页都用它, 不再拿条目 time_ms 猜。
  int? _cursor;
  bool _loadingMore = false;
  String? _olderError;

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

  /// 拉最新一页并与已加载的历史**按 id 合并去重**(下拉刷新不清历史)。
  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final List<rust.FeedEventDto> events;
      var more = false;
      if (widget.loadFeed != null) {
        events = await retryNetwork(widget.loadFeed!);
        more = events.length >= _pageSize;
      } else {
        // 真实游标分页: lastTime/more 由服务端给, 不再按"满页"猜
        final page = await retryNetwork(
          () => rust.feedPage(limit: _pageSize, lastTime: -1),
        );
        events = page.events;
        more = page.more;
        _cursor = page.lastTime;
      }
      if (!mounted) return;
      final hadHistory = (_events?.isNotEmpty ?? false);
      setState(() {
        // 刷新: 最新页优先(同 id 用最新副本, 点赞数等状态跟手), 历史只在末尾追加未重复的
        _events = mergeFeedEvents(events, _events ?? const []);
        // 首次加载才决定"还有没有更早"; 刷新不动已翻出的历史
        if (!hadHistory) _hasMore = more;
        // 选中的艺人还在列表里就保留, 否则回到"全部"
        if (_authorFilter != null &&
            !_events!.any((e) => e.userId == _authorFilter)) {
          _authorFilter = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  /// 滚动到底加载更早一页: 用当前列表最后一条的 time_ms 当游标。
  Future<void> _loadOlder() async {
    if (_loadingMore) return;
    final current = _events;
    if (current == null || current.isEmpty) return;
    setState(() {
      _loadingMore = true;
      _olderError = null;
    });
    // 优先用服务端游标; 还没拿到(例如注入了 loadFeed)时退回最后一条的 time_ms
    final cursor = _cursor ?? current.last.timeMs.toInt();
    try {
      final List<rust.FeedEventDto> older;
      var more = false;
      if (widget.loadOlder != null) {
        older = await retryNetwork(
          () => widget.loadOlder!(limit: _pageSize, lastTime: cursor),
        );
        more = older.length >= _pageSize;
      } else {
        final page = await retryNetwork(
          () => rust.feedPage(limit: _pageSize, lastTime: cursor),
        );
        older = page.events;
        more = page.more;
        _cursor = page.lastTime;
      }
      if (!mounted) return;
      setState(() {
        final merged = mergeFeedEvents(current, older);
        // 没有新增(全是重复 id / 游标没前进)就停, 否则会无限请求同一页
        final added = merged.length > current.length;
        _events = merged;
        _hasMore = added && more;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _olderError = friendlyError(e);
      });
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
      return const LoadingView();
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
        // 分页: 下拉刷新只重取最新页并与历史按 id 合并; 滚动到底(末尾 footer
        // 被构建时)再按最后一条的 time_ms 拉更早一页。
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: events.isEmpty
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 64),
                        child: EmptyView(
                          padding: EdgeInsets.zero,
                          title: _authorFilter == null ? '还没有动态' : 'ta 最近没有动态',
                        ),
                      ),
                    ],
                  )
                : ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                    // 末尾多一格 footer: 懒构建的 ListView 只在滚到底时构建它,
                    // footer 的 initState 就是"滚动到底加载更早"的触发器。
                    itemCount: events.length + (_hasMoreFooter ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= events.length) {
                        return _LoadOlderFooter(
                          busy: _loadingMore,
                          error: _olderError,
                          onLoad: _loadOlder,
                        );
                      }
                      return _FeedCard(
                        event: events[i],
                        onPlaySongs: widget.onPlaySongs,
                        onOpenUrl: widget.onOpenUrl,
                        onOpenChanged: _replace,
                        onLike: () => _toggleLike(events[i]),
                        forwardEvent: widget.forwardEvent,
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  /// 末尾 footer 何时出现: 还有更早一页, 或正在拉, 或上一页失败(给重试入口)
  bool get _hasMoreFooter => _hasMore || _loadingMore || _olderError != null;

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

/// 合并两页动态(刷新/加载更早共用): 按 id 去重, [first] 的副本优先(最新的
/// 点赞/评论状态跟手), [second] 中未出现过的条目按原顺序追加到末尾。
List<rust.FeedEventDto> mergeFeedEvents(
  List<rust.FeedEventDto> first,
  List<rust.FeedEventDto> second,
) {
  final seen = <BigInt>{};
  final out = <rust.FeedEventDto>[];
  void take(List<rust.FeedEventDto> src) {
    for (final e in src) {
      if (seen.add(e.id)) out.add(e);
    }
  }

  take(first);
  take(second);
  return out;
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
      // 定高横滑条: 头像/内边距固定, 只有 11sp 标签随字号涨(写死 84 时 1.625 下竖溢 4dp)
      height: avatarStripHeightFor(context),
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
              // 点头像进主页, 点整块仍是筛选(两者靠命中区区分, 见 _AuthorChip)。
              // 这里只有 feed 的 **user id**: 是艺人还是普通用户交给 UserNav 解析
              // (以前直接当 artistId 传, 会拿用户 id 去请求艺人详情)。
              userId: a.userId,
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
    this.userId,
    this.wide = false,
  });

  final String label;
  final String? avatarUrl;

  /// 有值 = 头像可点进这个人的主页(艺人页/用户页由 UserNav 解析);
  /// 为空(「全部」「进入全部」这类纯筛选入口)不拦截点击。
  final BigInt? userId;
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
                    // 只把 40dp 的头像包进 UserAvatarTap: 整块的 InkWell 仍是筛选,
                    // 命中区小才不会在点 chip 时误进主页。
                    : UserAvatarTap(
                        userId: userId ?? BigInt.zero,
                        nickname: label,
                        child: CircleCover(url: avatarUrl, size: 40),
                      ),
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

/// 列表末尾的"更早"footer: 懒构建的 ListView 只在滚到接近底部时构建它,
/// 因此 initState 就是"滚动到底自动加载更早一页"的触发器; 失败时给重试按钮。
class _LoadOlderFooter extends StatefulWidget {
  const _LoadOlderFooter({
    required this.busy,
    required this.error,
    required this.onLoad,
  });

  final bool busy;
  final String? error;
  final Future<void> Function() onLoad;

  @override
  State<_LoadOlderFooter> createState() => _LoadOlderFooterState();
}

class _LoadOlderFooterState extends State<_LoadOlderFooter> {
  @override
  void initState() {
    super.initState();
    _trigger();
  }

  @override
  void didUpdateWidget(covariant _LoadOlderFooter oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 上一页回来后又滚到底(或失败后重试成功): footer 还在树上时补一次触发
    if (oldWidget.busy && !widget.busy && widget.error == null) _trigger();
  }

  void _trigger() {
    if (widget.busy || widget.error != null) return;
    // 不能在 build/initState 里直接 setState 父级: 推到微任务后再触发
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.busy || widget.error != null) return;
      widget.onLoad();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (widget.error != null) {
      return Center(
        child: TextButton(
          onPressed: () => widget.onLoad(),
          child: Text('${widget.error!} (重试)'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: widget.busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                '加载更早的动态',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.outline,
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

  /// 分享面板(与详情页同源): 预览卡片 + 水印/二维码开关 + 系统分享/保存图片/
  /// 复制链接/转发动态。转发走 forwardEvent 注入(默认 rust.forwardEvent)。
  Future<void> _openShareSheet(BuildContext context) {
    return showFeedShareSheet(
      context,
      event: event,
      forwardEvent: forwardEvent,
    );
  }

  /// 长按动态 = 直接进转发面板(原动态预览 + 转发语 + 分享选项)
  Future<void> _openForwardSheet(BuildContext context) {
    return showFeedForwardSheet(
      context,
      event: event,
      forwardEvent: forwardEvent,
    );
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
        // 长按直接进转发面板(不必先点进详情页)
        onLongPress: () => _openForwardSheet(context),
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
                  // 原先这里有个「单曲 / 动态」kind 徽标: 用户反馈它不提供额外信息
                  // (点进详情就能看出来), 已去掉, 横向空间让给用户名与时间。
                  const SizedBox(width: 8),
                  // 时间是不可收缩的定宽尾部元素(与「我的」/消息页一致):
                  // 横向空间不足时先让用户名(Expanded)截断, 时间保持完整可读。
                  // maxLines/overflow 只兜底"时间本身比整行还宽"的极端字号。
                  Text(
                    feedRelativeTime(event.timeMs),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
              // 正文(最多 4 行, 详情页看全文)
              if (event.text.trim().isNotEmpty)
                Padding(
                  // 顶格(与卡片左缘对齐): 之前 left:50 想对齐用户名, 但头像 40 +
                  // 间距 10 的那一列在窄屏上会明显内缩, 正文每行前面多一段空白
                  // (用户反馈"动态文字左边有空白缩进, 应该取消").
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
                    const SizedBox(width: 16),
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

/// 单曲 mini 卡: CoverArt + 歌名/艺人 + play 图标, 点击播放这一首
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
                    SongTitleWithBadges(
                      song: song,
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
                    // 整行 = 筛选(把 userId 弹回 FeedView), 只有头像进主页。
                    // 本页作者只有 user id(不是 artist id), 交给 UserNav 解析。
                    leading: UserAvatarTap(
                      userId: a.userId,
                      nickname: a.name,
                      child: CircleCover(url: a.avatarUrl, size: 40),
                    ),
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
                  const LoadingView(
                    size: 20,
                    padding: EdgeInsets.symmetric(vertical: 16),
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
                      leading: ArtistAvatarTap(
                        artistId: a.id,
                        name: a.name,
                        child: CircleCover(url: a.avatarUrl, size: 40),
                      ),
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
