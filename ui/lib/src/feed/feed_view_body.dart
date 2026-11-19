/// 关注动态流的实现: 页面本体 + 状态机 + 数据工具 + 末尾 footer.
///
/// 拆分(2026-11-15): 卡片 → `feed_card.dart`, 艺人分类栏与「全部艺人」弹层 →
/// `artist_filter_bar.dart`; 三个文件同属一个库(part), 私有 `_` 符号不外泄。
library;

import 'package:flutter/material.dart';

import '../app_sheet.dart';
import '../artist_nav.dart';
import '../async_view.dart';
import '../cover_art.dart';
import '../feed_media.dart';
import '../feed_share.dart';
import '../error_views.dart';
import '../feed_detail_page.dart';
import '../layout.dart' show avatarStripHeightFor, kPagePadding;
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../toast.dart' show showToast;
import '../user_nav.dart';
import 'feed_merge.dart';
import '../sheet_header.dart';
import '../state_views.dart';
import '../wheel_refresh.dart';

part 'artist_filter_bar.dart';
part 'feed_card.dart';

/// 动态分页加载器: limit = 每页条数, lastTime = 上一页最后一条的 time_ms(unix 毫秒;
/// -1 表示"最新一页", 见 ncm-api 的 lasttime 语义)。
typedef FeedPageLoader = Future<List<rust.FeedEventDto>> Function({
  required int limit,
  required int lastTime,
});

/// 单个艺人的动态加载器: uid = 艺人账号 uid, lastTime = 上一页最后一条的
/// time_ms(-1 = 最新一页)。与关注流共用 lasttime 语义, 但端点不同
/// (/api/event/get/{uid}), 所以单独一个 typedef 便于测试注入。
typedef ArtistFeedLoader = Future<List<rust.FeedEventDto>> Function({
  required BigInt uid,
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
    required this.onOpenUrl, // Future<void> Function(String url) —— 视频交给系统打开
    this.loadFeed, // 测试注入
    this.loadSubscribedArtists, // 测试注入(关注艺人, 用于"全部艺人"面板)
    this.likeEvent, // 测试注入(列表行点赞, 默认 rust.likeEvent)
    this.forwardEvent, // 测试注入(列表行转发, 默认 rust.forwardEvent)
    this.loadOlder, // 测试注入(滚动到底加载更早一页, 默认 rust.feedEvents)
    this.loadArtistEvents, // 测试注入(选中艺人后的历史流, 默认 rust.userEvents)
  });

  final bool loggedIn;
  final VoidCallback onLogin;
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

  /// 选中某个艺人后的动态加载器: 默认 rust.userEvents(uid, limit, lastTime)。
  /// 关注流的最近一页里某个艺人常常只有 1 条, 想看 ta 的历史必须换数据源。
  final ArtistFeedLoader? loadArtistEvents;

  @override
  State<FeedView> createState() => _FeedViewState();
}

class _FeedViewState extends State<FeedView> {
  /// 已加载的动态(最新页 + 翻出来的历史, 按 id 去重)。
  ///
  /// 用**就地合并**(clear + addAll)而不是换列表实例: 它的同一个实例也是喂给
  /// [AsyncView] 的 data, 换实例会让 AsyncView 的空态判定停在旧快照上
  /// (刷新把空列表填满后仍显示"还没有动态")。
  final List<rust.FeedEventDto> _events = <rust.FeedEventDto>[];

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

  /// 选中艺人的名字/头像快照: 该艺人可能不在当前关注流这一页里,
  /// 靠它把 chip 钉在横条上, 否则横条会把「全部」误标成选中。
  _Author? _pinnedAuthor;

  // ── 选中艺人后的独立动态流 ──────────────────────────────────────────────
  //
  // 关注流只有最近一页: 某个艺人常常只出现 1 条(用户 2026-11-19: 发条月亮
  // 主页 3 条, 关注页只看到 1 条; 实测主页接口有 16 条)。选中艺人后
  // 数据源切到 /api/event/get/{uid}, 并用 lasttime 贪婪往前翻历史。
  // 这份列表与 [_events] 完全分开, 切回「全部」不会串号。

  /// 该艺人的动态(最新页 + 已翻出的历史, 按 id 去重)
  final List<rust.FeedEventDto> _artistEvents = <rust.FeedEventDto>[];

  /// 请求代号: 切艺人/重试时 +1, 回包代号不一致就丢弃(慢请求不能覆盖新选择)
  int _artistEpoch = 0;

  /// 该艺人首屏是否在途
  bool _artistLoading = false;

  /// 该艺人首屏错误的文案(只在列表为空时整块展示; 有数据时按下拉刷新口径只提示)
  String? _artistError;

  /// 该艺人是否还有更早一页(上一页满页才算)
  bool _artistHasMore = false;

  /// 该艺人「更早一页」是否在途
  bool _artistLoadingMore = false;

  /// 该艺人「更早一页」的错误(footer 重试口径与关注流一致)
  String? _artistOlderError;

  /// 该艺人历史游标 = 已合并列表最后一条的 time_ms。
  /// user_event 的 lasttime 是**排他**的(实测 2026-11-19:
  /// user-events 382104588 20 1707108250173 只回比它更早的 13 条)。
  int? _artistCursor;

  // 首屏取数不在 initState 里: 四态收敛到 [AsyncView](挂载即取、出错时可重试)。
  // 登录态从无到有时整块按 ValueKey 重挂载(main.dart), 会自动重取。

  /// 取最新一页(不套 [retryNetwork]: AsyncView 的 load 形态会自己套,
  /// 下拉刷新入口单独套一层, 免得同一次请求包两层退避)。
  Future<({List<rust.FeedEventDto> events, bool more})> _fetchLatest() async {
    if (widget.loadFeed != null) {
      final events = await widget.loadFeed!();
      return (events: events, more: events.length >= _pageSize);
    }
    // 真实游标分页: lastTime/more 由服务端给, 不再按"满页"猜
    final page = await rust.feedPage(limit: _pageSize, lastTime: -1);
    // 游标只在**还没翻过页**时确立: 下拉刷新拿到的是"最新页"的游标, 拿它覆盖
    // 已翻出的历史游标会让 [loadOlder] 回头重取同一段(条目重复 + 游标不前进,
    // 于是提前判定"没有更早"并停掉分页)。
    _cursor ??= page.lastTime;
    return (events: page.events, more: page.more);
  }

  /// 把最新一页并进 [_events]: 最新页优先(同 id 用最新副本, 点赞数等状态跟手),
  /// 历史只在末尾追加未重复的。返回的就是 [_events] 本身(见字段注释)。
  /// [more] 只在首次加载时决定"还有没有更早", 刷新不动已翻出的历史。
  List<rust.FeedEventDto> _mergeLatest(
    List<rust.FeedEventDto> latest, {
    required bool more,
  }) {
    final hadHistory = _events.isNotEmpty;
    final merged = mergeFeedEvents(latest, _events);
    _events
      ..clear()
      ..addAll(merged);
    if (!hadHistory) _hasMore = more;
    // 选中的艺人不再依赖关注流里是否还有 ta 的条目: 选中后数据源已切到
    // 该艺人自己的动态流, chip 靠 [_pinnedAuthor] 钉住(见 [_selectAuthor])。
    return _events;
  }

  /// [AsyncView] 的取数入口(组件自己套 [retryNetwork]): 最新页与已加载历史
  /// 合并去重, 下拉刷新不清历史。
  Future<List<rust.FeedEventDto>> _loadInitial() async {
    final page = await _fetchLatest();
    return _mergeLatest(page.events, more: page.more);
  }

  /// 下拉刷新: 只重取最新页并与历史合并, 不经过 AsyncView(免得整页闪回加载态);
  /// 失败保留已渲染的列表只弹提示, 不把已翻出来的历史打成整页错误。
  Future<void> _refresh() async {
    if (_authorFilter != null) {
      await _refreshArtist();
      return;
    }
    try {
      final page = await retryNetwork(_fetchLatest);
      if (!mounted) return;
      setState(() => _mergeLatest(page.events, more: page.more));
    } catch (e) {
      if (!mounted) return;
      _snack('刷新失败: ${friendlyError(e)}');
    }
  }

  /// 滚动到底加载更早一页: 用当前列表最后一条的 time_ms 当游标。
  Future<void> _loadOlder() async {
    if (_loadingMore) return;
    final current = _events;
    if (current.isEmpty) return;
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
        _events
          ..clear()
          ..addAll(merged);
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

  // ── 选中艺人: 独立动态流(首屏 / 贪婪翻历史 / 刷新合并) ─────────────────

  /// 该艺人动态的取数入口(注入优先, 默认 rust.userEvents)
  Future<List<rust.FeedEventDto>> _fetchArtist(BigInt uid, int lastTime) {
    final load = widget.loadArtistEvents ?? _defaultArtistEvents;
    return load(uid: uid, limit: _pageSize, lastTime: lastTime);
  }

  Future<List<rust.FeedEventDto>> _defaultArtistEvents({
    required BigInt uid,
    required int limit,
    required int lastTime,
  }) => rust.userEvents(uid: uid, limit: limit, lastTime: lastTime);

  /// 选中/取消选中某个艺人: 切换时重置游标与列表(不串号), 选中就取最新一页。
  void _selectAuthor(_Author? author) {
    final id = author?.userId;
    if (id == _authorFilter) {
      if (id != null && author != null) {
        setState(() => _pinnedAuthor = author);
      }
      return;
    }
    final epoch = ++_artistEpoch;
    setState(() {
      _authorFilter = id;
      _pinnedAuthor = author;
      _artistEvents.clear();
      _artistHasMore = false;
      _artistLoadingMore = false;
      _artistOlderError = null;
      _artistError = null;
      _artistCursor = null;
      _artistLoading = id != null;
    });
    if (id != null) _loadArtistLatest(id, epoch);
  }

  /// 该艺人最新一页(选中后的首屏, 也是「重试」的入口)
  Future<void> _loadArtistLatest(BigInt uid, int epoch) async {
    try {
      final events = await retryNetwork(() => _fetchArtist(uid, -1));
      if (!mounted || epoch != _artistEpoch) return;
      setState(() {
        final head = _artistEvents.isEmpty;
        final merged = mergeFeedEvents(events, _artistEvents);
        _artistEvents
          ..clear()
          ..addAll(merged);
        if (head) _artistHasMore = events.length >= _pageSize;
        _artistCursor = _artistEvents.isEmpty
            ? null
            : _artistEvents.last.timeMs.toInt();
        _artistLoading = false;
        _artistError = null;
      });
    } catch (e) {
      if (!mounted || epoch != _artistEpoch) return;
      setState(() {
        _artistLoading = false;
        _artistError = friendlyError(e);
      });
    }
  }

  /// 首屏失败后重试: 重新从最新一页取(游标归零)
  void _retryArtist() {
    final uid = _authorFilter;
    if (uid == null) return;
    final epoch = ++_artistEpoch;
    setState(() {
      _artistError = null;
      _artistLoading = true;
      _artistEvents.clear();
      _artistCursor = null;
      _artistHasMore = false;
      _artistOlderError = null;
    });
    _loadArtistLatest(uid, epoch);
  }

  /// 下拉刷新(艺人模式): 重取该艺人最新一页, 与已加载历史按 id 合并,
  /// 新条目插在最前, 历史一条都不丢。
  Future<void> _refreshArtist() async {
    final uid = _authorFilter;
    if (uid == null) return;
    final epoch = _artistEpoch;
    try {
      final events = await retryNetwork(() => _fetchArtist(uid, -1));
      if (!mounted || epoch != _artistEpoch) return;
      setState(() {
        final merged = mergeFeedEvents(events, _artistEvents);
        _artistEvents
          ..clear()
          ..addAll(merged);
        _artistCursor = _artistEvents.isEmpty
            ? null
            : _artistEvents.last.timeMs.toInt();
        _artistError = null;
      });
    } catch (e) {
      if (!mounted) return;
      // 有数据时刷新失败保留列表, 只提示(与关注流同口径)
      _snack('刷新失败: ${friendlyError(e)}');
    }
  }

  /// 滚到底: 用该艺人列表最后一条的 time_ms 往前取, 合并去重后继续追加,
  /// 直到返回空/不满一页(贪婪加载历史)。
  Future<void> _loadArtistOlder() async {
    final uid = _authorFilter;
    if (uid == null || _artistLoadingMore || !_artistHasMore) return;
    final epoch = _artistEpoch;
    final cursor =
        _artistCursor ??
        (_artistEvents.isEmpty ? -1 : _artistEvents.last.timeMs.toInt());
    setState(() {
      _artistLoadingMore = true;
      _artistOlderError = null;
    });
    try {
      final older = await retryNetwork(() => _fetchArtist(uid, cursor));
      if (!mounted || epoch != _artistEpoch) return;
      setState(() {
        final before = _artistEvents.length;
        final merged = mergeFeedEvents(_artistEvents, older);
        _artistEvents
          ..clear()
          ..addAll(merged);
        // 没有新增(全是重复 id / 游标没前进)就停, 否则会无限请求同一页
        final added = merged.length > before;
        _artistHasMore = added && older.length >= _pageSize;
        _artistCursor = merged.isEmpty ? null : merged.last.timeMs.toInt();
        _artistLoadingMore = false;
      });
    } catch (e) {
      if (!mounted || epoch != _artistEpoch) return;
      setState(() {
        _artistLoadingMore = false;
        _artistOlderError = friendlyError(e);
      });
    }
  }

  /// 横条要展示的作者: 关注流里的作者 + 被钉住的选中艺人(可能不在本页)
  List<_Author> get _barAuthors {
    final authors = _authors;
    final pinned = _pinnedAuthor;
    if (pinned == null) return authors;
    if (authors.any((a) => a.userId == pinned.userId)) return authors;
    return [pinned, ...authors];
  }

  /// 本页出现过的发布者, 按"互动频率"从高到低(详见 [_Author.score]).
  /// 同分保持首次出现顺序(≈ 最近一次发动态的时间), 避免分类行顺序乱跳.
  List<_Author> get _authors {
    final byKey = <BigInt, _Author>{};
    var firstSeen = 0;
    for (final e in _events) {
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

  /// 打开"全部艺人"面板: 本页发布者(按频率) + 关注但本页没发动态的艺人
  Future<void> _openAllArtists() async {
    final selected = await showAppSheet<_Author>(
      context,
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
    // null = 用户取消(不动筛选); userId == 0 = 面板里的"全部动态"(清筛选)
    if (selected == null || !mounted) return;
    _selectAuthor(selected.userId == BigInt.zero ? null : selected);
  }

  /// 当前要渲染的列表: 选中艺人时用该艺人自己的动态流, 否则用关注流
  List<rust.FeedEventDto> get _visible =>
      _authorFilter == null ? _events : _artistEvents;

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
    // 整块四态收敛到 AsyncView: 加载中整块 LoadingView, 出错居中提示 + 重试,
    // 空态与数据态共用 _feedBody(空态也要保留艺人筛选条与下拉刷新)。
    return AsyncView<List<rust.FeedEventDto>>(
      load: _loadInitial,
      emptyText: '还没有动态',
      loadingBuilder: (_) => const LoadingView(),
      emptyBuilder: (_) => _feedBody(),
      errorBuilder: (context, error, retry) =>
          _errorView(context, friendlyError(error), retry),
      builder: (_, _, _) => _feedBody(),
    );
  }

  /// 整块错误态(改造前就是这个形态: 居中错误文案 + 重试按钮)
  Widget _errorView(BuildContext context, String message, VoidCallback retry) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: retry, child: const Text('重试')),
        ],
      ),
    );
  }

  Widget _feedBody() {
    final events = _visible;
    final authors = _authors;
    final artistMode = _authorFilter != null;
    final artistLoading = artistMode && _artistLoading && _artistEvents.isEmpty;
    final artistFailed =
        artistMode && _artistError != null && _artistEvents.isEmpty;
    return Column(
      children: [
        // 放几个由横条自己的 LayoutBuilder 按实宽算(visibleAuthorCountFor),
        // 这里把**全部**作者交下去: 宽屏能多放, 窄屏仍可横滑。
        // 选中艺人可能不在关注流这一页里(ta 最近的动态是老的), 用
        // [_barAuthors] 把他钉在横条上, 否则"全部"会被误标成选中。
        _ArtistFilterBar(
          authors: _barAuthors,
          totalAuthors: authors.length,
          selected: _authorFilter,
          onSelected: _selectAuthor,
          onOpenAll: _openAllArtists,
        ),
        // 分页: 下拉刷新只重取最新页并与历史按 id 合并; 滚动到底(末尾 footer
        // 被构建时)再按最后一条的 time_ms 拉更早一页。艺人模式用自己的游标。
        Expanded(
          // 桌面(鼠标/触控板)没有手指下拉: 滚轮到顶继续上滚也算一次刷新,
          // 冷却期内只算一次(见 [WheelRefreshable])。
          child: WheelRefreshable(
            onRefresh: _refresh,
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: artistLoading
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: LoadingView(),
                        ),
                      ],
                    )
                  : artistFailed
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 32,
                          ),
                          child: InlineError(
                            message: _artistError!,
                            onRetry: _retryArtist,
                          ),
                        ),
                      ],
                    )
                  : events.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 64),
                          child: EmptyView(
                            padding: EdgeInsets.zero,
                            title: _authorFilter == null
                                ? '还没有动态'
                                : 'ta 最近没有动态',
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      // 水平 = kPagePadding, 与顶部横条同一口径(左右边缘共线)
                      padding: const EdgeInsets.fromLTRB(
                        kPagePadding,
                        4,
                        kPagePadding,
                        24,
                      ),
                      // 末尾多一格 footer: 懒构建的 ListView 只在滚到底时构建它,
                      // footer 的 initState 就是"滚动到底加载更早"的触发器。
                      itemCount: events.length + (_hasMoreFooter ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i >= events.length) {
                          return _LoadOlderFooter(
                            busy: artistMode
                                ? _artistLoadingMore
                                : _loadingMore,
                            error: artistMode ? _artistOlderError : _olderError,
                            onLoad: artistMode ? _loadArtistOlder : _loadOlder,
                          );
                        }
                        return _FeedCard(
                          event: events[i],
                          onOpenUrl: widget.onOpenUrl,
                          onOpenChanged: _replace,
                          onLike: () => _toggleLike(events[i]),
                          forwardEvent: widget.forwardEvent,
                        );
                      },
                    ),
            ),
          ),
        ),
      ],
    );
  }

  /// 末尾 footer 何时出现: 还有更早一页, 或正在拉, 或上一页失败(给重试入口)
  bool get _hasMoreFooter => _authorFilter == null
      ? (_hasMore || _loadingMore || _olderError != null)
      : (_artistHasMore || _artistLoadingMore || _artistOlderError != null);

  /// 详情页点赞回来后同步列表里的状态
  void _replace(rust.FeedEventDto updated) {
    // 关注流与艺人流是两份列表: 同一条动态可能在任一份里, 两处都刷(按 id 找)
    var found = false;
    for (final list in [_events, _artistEvents]) {
      final index = list.indexWhere((e) => e.id == updated.id);
      if (index < 0) continue;
      list[index] = updated;
      found = true;
    }
    if (found) setState(() {});
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
    var found = false;
    for (final list in [_events, _artistEvents]) {
      final index = list.indexWhere((e) => e.id == id);
      if (index < 0) continue;
      list[index] = _copyEventWith(
        list[index],
        liked: liked,
        likedCount: likedCount,
      );
      found = true;
    }
    if (found) setState(() {});
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
