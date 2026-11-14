import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'artist_nav.dart';
import 'async_view.dart';
import 'cover_art.dart';
import 'cover_row.dart';
import 'detail_page.dart';
import 'error_views.dart';
import 'expandable_text.dart';
import 'feed_detail_page.dart' show feedKindLabels, feedRelativeTime, showFeedDetail;
import 'layout.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'platform.dart';
import 'profile_banner.dart';
import 'profile_scaffold.dart';
import 'rust/api.dart' as rust;
import 'section_header.dart';
import 'state_views.dart';
import 'toast.dart';
import 'user_list_page.dart';

/// 他人主页: 与艺人页共用 [ProfileScaffold] 骨架(横幅 + 身份卡 + 统计 chip +
/// 分区 + pinned TabBar), 内容分 tab: 歌单 / 关注(有才显示) / 粉丝(有才显示).
///
/// 为什么需要它: 听众列表(radio_subscribers_page)与关注/粉丝列表(user_list_page)
/// 早就能列出用户, 但点不动 —— 没有"用户主页"这个目的地. 数据面用
/// `user_profile`(user/detail, 匿名可用) + `user_playlists_of`(user/playlist)
/// + `user_follows`/`user_followeds`(关注/粉丝列表).
///
/// 只读边界: 不在本页做关注/取关、不发私信、不进对方"我喜欢的音乐"(私密歌单,
/// 服务端也不会回); 关注/粉丝 chip 只是入口(切 tab, 或退到关注与粉丝列表页).
class UserPage extends StatefulWidget {
  const UserPage({
    super.key,
    required this.userId,
    this.fallbackNickname,
    this.onPlaySongs,
    this.loadProfile,
    this.loadPlaylists,
    this.loadFollows,
    this.loadFolloweds,
    this.onOpenFollows,
    this.onOpenFolloweds,
    this.loadEvents,
    this.onOpenUrl,
    this.initialTab,
  });

  final BigInt userId;
  final String? fallbackNickname;

  /// 点歌单后播放回调(宿主注入); 为空时歌单只展示不可播(测试/无播放器场景)
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  /// 测试注入
  final Future<rust.ProfileDetail> Function(BigInt uid)? loadProfile;
  final Future<List<rust.Playlist>> Function(BigInt uid)? loadPlaylists;

  /// 关注/粉丝列表 loader(测试注入; 默认走 rust.userFollows/userFolloweds)
  final UserListLoader? loadFollows;
  final UserListLoader? loadFolloweds;

  /// 关注/粉丝 chip 的处理器(宿主可覆盖导航目标; 不传则切自身 tab)
  final VoidCallback? onOpenFollows;
  final VoidCallback? onOpenFolloweds;

  /// 动态 loader(测试注入; 默认 rust.userEvents 取第一页 30 条)
  final Future<List<rust.FeedEventDto>> Function(BigInt uid)? loadEvents;

  /// 动态详情里打开外链/视频(默认交给系统, 见 [PlatformBridge.openUrl])
  final Future<void> Function(String url)? onOpenUrl;

  /// 打开时定位到哪条 tab(按 label 匹配, 如「动态」); 不存在则落在第一条
  final String? initialTab;

  @override
  State<UserPage> createState() => _UserPageState();
}

class _UserPageState extends State<UserPage> with TickerProviderStateMixin {
  rust.ProfileDetail? _detail;
  List<rust.Playlist>? _playlists;
  String? _error;
  bool _loading = true;

  final ScrollController _scroll = ScrollController();
  bool _collapsed = false;
  /// 首帧就要与 [_tabSpecs] 的条数一致(「动态」是恒定 tab): 先用数据无关的
  /// 条数建 controller, 资料回来后再由 [_rebuildTabs] 按关注/粉丝补齐。
  late TabController _tabController;

  Future<rust.ProfileDetail> Function(BigInt uid) get _loadProfile =>
      widget.loadProfile ?? (uid) => rust.userProfile(userId: uid);

  Future<List<rust.Playlist>> Function(BigInt uid) get _loadPlaylists =>
      widget.loadPlaylists ??
      (uid) => rust.userPlaylistsOf(userId: uid, limit: 50);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _tabController = TabController(length: _tabCount, vsync: this);
    _reload();
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _tabController.dispose();
    super.dispose();
  }

  void _onScroll() {
    final collapsed = profileCollapsedAt(_scroll);
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  /// tab 数量以 [_tabSpecs] 为唯一来源(原来这里是第二份手写计数,
  /// 加一条 tab 就得同时改两处, 漏改会让 controller 与 TabBar 长度不一致)。
  int get _tabCount => _tabSpecs().length;

  /// [UserPage.initialTab] 只生效一次: 之后用户自己切 tab / 刷新重拉都不再抢回.
  bool _appliedInitialTab = false;

  int? _pendingTabIndex() {
    if (_appliedInitialTab) return null;
    final label = widget.initialTab;
    if (label == null) return null;
    final index = _tabSpecs().indexWhere((s) => s.label == label);
    return index < 0 ? null : index;
  }

  void _rebuildTabs() {
    final target = _pendingTabIndex();
    _tabController = syncProfileTabs(
      vsync: this,
      current: _tabController,
      length: _tabCount,
      onChanged: () => setState(() {}),
      initialIndex: target,
    );
    if (target == null) return;
    // syncProfileTabs 在页数没变时返回原 controller(不带 initialIndex) ⇒ 补一次跳转
    if (_tabController.index != target) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabController.index != target) {
          _tabController.animateTo(target);
        }
      });
    }
    _appliedInitialTab = true;
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 资料与歌单互不阻塞: 任一失败不该让另一块空白
      final results = await Future.wait<Object?>([
        retryNetwork(() => _loadProfile(widget.userId)),
        retryNetwork(() => _loadPlaylists(widget.userId)),
      ]);
      if (!mounted) return;
      setState(() {
        _detail = results[0] as rust.ProfileDetail?;
        _playlists = results[1] as List<rust.Playlist>?;
        _loading = false;
      });
      _rebuildTabs();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  Future<void> _openPlaylist(rust.Playlist playlist) async {
    final play = widget.onPlaySongs;
    if (play == null) {
      showToast(context, '当前页面不支持播放');
      return;
    }
    await showPlaylistDetail(
      context,
      playlistId: playlist.id,
      name: playlist.name,
      coverUrl: playlist.coverUrl,
      special: playlist.special,
      onPlaySongs: play,
    );
  }

  /// 关注/粉丝 chip 入口: 宿主有钩子就交给宿主; 本页有对应 tab 就切过去;
  /// 否则(计数为 0 / 未知, tab 未生成)退到独立的关注与粉丝列表页。
  Future<void> _openRelationship({required bool fans}) async {
    final hook = fans ? widget.onOpenFolloweds : widget.onOpenFollows;
    if (hook != null) {
      hook();
      return;
    }
    final index = _tabSpecs().indexWhere(
      (s) => s.label == (fans ? '粉丝' : '关注'),
    );
    if (index >= 0) {
      _tabController.animateTo(index);
      return;
    }
    await showUserList(
      context,
      uid: widget.userId,
      startOnFans: fans,
      loadFollows: widget.loadFollows,
      loadFolloweds: widget.loadFolloweds,
      onPlaySongs: widget.onPlaySongs,
    );
  }

  String get _nickname {
    final d = _detail;
    if (d != null && d.nickname.isNotEmpty) return d.nickname;
    return widget.fallbackNickname ?? '用户';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nickname = _nickname;
    // 首屏失败(资料与歌单都拿不到): 整页错误 + 重试(与艺人页同一形态)
    if (_detail == null && _error != null) {
      return ProfileLoadError(
        title: nickname,
        message: _error!,
        onRetry: _reload,
      );
    }
    return ProfileScaffold(
      scrollController: _scroll,
      collapsedTitle: _collapsed ? nickname : null,
      banner: ProfileBannerImage(url: _detail?.backgroundUrl),
      identity: _buildIdentity(theme, nickname),
      // 与艺人页同一骨架的同一批「可选区块」: 有数据才渲染, 缺数据整块不出现
      sections: _buildInfoSections(theme),
      tabs: _tabSpecs(),
      controller: _tabController,
    );
  }

  /// 信息区(横幅与 TabBar 之间): 目前只有「简介」。
  ///
  /// 艺人页在这里放 相似艺人/简介/推荐单曲/专辑, 用户页没有对应数据 ⇒ 只剩简介;
  /// 机制是同一套: 返回一组 widget, 空列表 = 不出区块, 骨架完全相同。
  List<Widget> _buildInfoSections(ThemeData theme) {
    final signature = _detail?.signature.trim() ?? '';
    if (signature.isEmpty) return const <Widget>[];
    // 与艺人页同一份分区几何(标题 8 / 内容 / 块间 16), 见 ProfileSection
    return [
      ProfileSection(
        title: '简介',
        child: ExpandableText(text: signature),
      ),
    ];
  }

  /// 身份卡: 头像/昵称/VIP/签名 + 统一统计 chip(关注/粉丝可点, 等级只展示)
  Widget _buildIdentity(ThemeData theme, String nickname) {
    final d = _detail;
    final loading = _loading && d == null;
    return ProfileIdentity(
      title: nickname,
      // 签名移到「简介」区块(与艺人页一致): 身份卡副标题只放次要身份信息
      subtitle: null,
      avatarUrl: d?.avatarUrl,
      vip: d?.vip ?? false,
      // 需求 11: 关注/粉丝/等级**单独一行**, 落在头像右侧、昵称下方(meta 槽位),
      // 不再占整卡底部的一行 —— 后者与头像左边缘对齐, 视觉上像另一段内容.
      // 加载中不塞「加载中…」占位 chip, 也不先给一套 0 值: 缺的条目不显示,
      // 数据到了再出现(与艺人页"作品数为 0 不渲染统计行"同一口径)
      meta: loading ? null : ProfileStatRow(chips: _statChips(d, nickname)),
    );
  }

  /// 统计 chip 组: 关注 / 粉丝(可点) / 等级 / 歌手页入口。
  ///
  /// 需求 12: Lv 数值来自 rust.ProfileDetail.level(user/detail 的 level);
  /// **0 / 缺失一律不渲染徽标** —— 之前缺数据时会掉出「Lv.0」, 比不显示更像 bug。
  List<Widget> _statChips(rust.ProfileDetail? d, String nickname) {
    final artistId = d?.artistId;
    final level = d?.level ?? BigInt.zero;
    return [
      ProfileStatChip(
        icon: Icons.people_outline,
        label: '关注 ${d?.follows ?? BigInt.zero}',
        onTap: () => _openRelationship(fans: false),
      ),
      ProfileStatChip(
        icon: Icons.person_outline,
        label: '粉丝 ${d?.followeds ?? BigInt.zero}',
        onTap: () => _openRelationship(fans: true),
      ),
      if (level > BigInt.zero)
        ProfileStatChip(
          icon: Icons.military_tech_outlined,
          label: 'Lv.$level',
        ),
      // 有歌手身份(= user_detail 带回 artistId)才给「歌手页」入口:
      // 音乐人的用户主页与艺人主页是两份数据, 这里补上另一个入口
      // (动态头像点击则由 UserNav 直接进艺人页)。
      if (artistId != null)
        ProfileStatChip(
          icon: Icons.mic_none,
          label: '歌手页',
          onTap: () => ArtistNav.open(context, artistId, name: nickname),
        ),
    ];
  }

  Future<List<rust.FeedEventDto>> Function(BigInt uid) get _loadEvents =>
      widget.loadEvents ?? _defaultEvents;

  /// 默认 loader 必须是 async 函数: 直接写成箭头闭包时, FFI 缺失/同步抛错会在
  /// AsyncView 的 initState 里同步冒出来(整棵子树建不出来), 而不是变成 Future 错误。
  static Future<List<rust.FeedEventDto>> _defaultEvents(BigInt uid) async =>
      rust.userEvents(uid: uid, limit: 30, lastTime: -1);

  /// 动态 tab: 与「我的」页「我的动态」区块同一份列表(见 [UserEventsList]),
  /// 自带下拉刷新 —— 动态是唯一会「新内容随时出现」的 tab。
  Widget _eventsTab(BuildContext context) {
    final bottom = 24 + MediaQuery.viewPaddingOf(context).bottom;
    return _RefreshableEvents(
      load: () => _loadEvents(widget.userId),
      padding: EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, bottom),
      onPlaySongs: widget.onPlaySongs,
      onOpenUrl: widget.onOpenUrl,
    );
  }

  /// 声明式 tab 集合(与艺人页同一机制: 按数据可用性生成)。
  ///
  /// 「动态」固定第一条: 它是用户主页的主内容(网易云同款次序), 空/失败由
  /// tab 内自己给空态 —— 不像关注/粉丝那样"计数为 0 就没有这条数据"。
  List<ProfileTabSpec> _tabSpecs() {
    final d = _detail;
    final follows = d?.follows ?? BigInt.zero;
    final followeds = d?.followeds ?? BigInt.zero;
    return [
      ProfileTabSpec('动态', builder: _eventsTab),
      ProfileTabSpec('歌单', builder: _playlistsTab),
      if (follows > BigInt.zero)
        ProfileTabSpec(
          '关注',
          badge: ProfileTabBadge('$follows'),
          builder: (context) => _relationTab(context, fans: false),
        ),
      if (followeds > BigInt.zero)
        ProfileTabSpec(
          '粉丝',
          badge: ProfileTabBadge('$followeds'),
          builder: (context) => _relationTab(context, fans: true),
        ),
    ];
  }

  /// 歌单 tab: 横滑卡片(CoverRow/CoverCard), 标题允许 2 行。
  Widget _playlistsTab(BuildContext context) {
    final lists = _playlists;
    final bottom = 24 + MediaQuery.viewPaddingOf(context).bottom;
    if (_error != null && lists == null) {
      // 与艺人页 tab 内错误同一形态(行内文案 + 重试), 不再塞一张 Card
      return ListView(
        padding: EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, bottom),
        children: [InlineError(message: _error!, onRetry: _reload)],
      );
    }
    if (lists == null) {
      return const LoadingView(message: '正在加载歌单…');
    }
    if (lists.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: EdgeInsets.fromLTRB(kPagePadding, 24, kPagePadding, bottom),
          children: const [
            EmptyView(
              icon: Icons.queue_music,
              title: '没有公开歌单',
              hint: '对方可能没建过歌单, 或歌单都设为私密',
            ),
          ],
        ),
      );
    }
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        // 右侧不留白: 横滑轨道要能滚到屏幕边缘
        padding: EdgeInsets.fromLTRB(kPagePadding, 8, 0, bottom),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: kPagePadding),
            child: SectionHeader(
              title: 'TA 的歌单',
              trailing: Text(
                '${lists.length} 个',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          CoverRow(
            children: [
              for (final p in lists.take(30))
                CoverCard(
                  coverUrl: p.coverUrl,
                  title: p.name,
                  subtitle: '${p.trackCount} 首',
                  onTap: () => _openPlaylist(p),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 关注/粉丝 tab: 只读列表(点行进对方主页)
  Widget _relationTab(BuildContext context, {required bool fans}) {
    final loader =
        (fans ? widget.loadFolloweds : widget.loadFollows) ??
        (fans
            ? (uid, limit, offset) =>
                  rust.userFolloweds(uid: uid, limit: limit, offset: offset)
            : (uid, limit, offset) =>
                  rust.userFollows(uid: uid, limit: limit, offset: offset));
    return _RelationListView(
      uid: widget.userId,
      fans: fans,
      loader: loader,
      onPlaySongs: widget.onPlaySongs,
    );
  }
}

/// 关注/粉丝列表(带分页/空态/重试), 点行进对方主页。
class _RelationListView extends StatelessWidget {
  const _RelationListView({
    required this.uid,
    required this.fans,
    required this.loader,
    this.onPlaySongs,
  });

  final BigInt uid;
  final bool fans;
  final UserListLoader loader;
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;

  @override
  Widget build(BuildContext context) {
    const pageSize = 30;
    return PagedListView<rust.UserItem>(
      key: ValueKey('user-relation-$fans'),
      pageSize: pageSize,
      keyOf: (u) => u.id,
      emptyText: fans ? '还没有粉丝' : '还没有关注任何人',
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      loader: (cursor) async {
        final page = await retryNetwork(() => loader(uid, pageSize, cursor));
        return PagedPage(
          page,
          hasMore: page.length >= pageSize,
          nextCursor: cursor + page.length,
        );
      },
      itemBuilder: (context, u, index, items) => ListTile(
        leading: CircleCover(
          url: u.avatarUrl,
          size: 40,
          icon: Icons.person_outline,
        ),
        title: AdaptiveText(u.name),
        subtitle: Text(
          u.signature.isEmpty ? '暂无签名' : u.signature,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => showUserPage(
          context,
          userId: u.id,
          fallbackNickname: u.name,
          onPlaySongs: onPlaySongs,
        ),
      ),
    );
  }
}

/// 可下拉刷新的动态列表(用户主页「动态」tab 用)。
///
/// [UserEventsList] 自己不持有滚动容器(它同时被「我的」页嵌进整页 ListView),
/// 所以"下拉刷新"由这里提供: 换 generation key 让 AsyncView 重新取数。
class _RefreshableEvents extends StatefulWidget {
  const _RefreshableEvents({
    required this.load,
    required this.padding,
    this.onPlaySongs,
    this.onOpenUrl,
  });

  final Future<List<rust.FeedEventDto>> Function() load;
  final EdgeInsetsGeometry padding;
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;
  final Future<void> Function(String url)? onOpenUrl;

  @override
  State<_RefreshableEvents> createState() => _RefreshableEventsState();
}

class _RefreshableEventsState extends State<_RefreshableEvents> {
  int _generation = 0;

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() => _generation += 1),
      // AlwaysScrollable: 只有一两张卡(或空态)时也要能下拉
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: widget.padding,
        children: [
          UserEventsList(
            key: ValueKey('user-events-$_generation'),
            load: widget.load,
            onPlaySongs: widget.onPlaySongs,
            onOpenUrl: widget.onOpenUrl,
            emptyText: 'TA 还没有发布动态',
          ),
        ],
      ),
    );
  }
}

/// 用户动态列表(用户主页「动态」tab 与「我的」页「我的动态」区块**共用**)。
///
/// 只渲染"卡片 + 四态"(走 [AsyncView]), 不自带滚动容器:
/// · tab 里外层是 [_RefreshableEvents](下拉刷新);
/// · 「我的」页嵌在整页 ListView 里, 由整页的下拉刷新代际换 key 重拉。
class UserEventsList extends StatelessWidget {
  const UserEventsList({
    super.key,
    required this.load,
    this.onPlaySongs,
    this.onOpenUrl,
    this.emptyText = '还没有发布动态',
    this.maxItems,
  });

  /// 取数(不含重试, 重试由 [AsyncView] 套 retryNetwork)
  final Future<List<rust.FeedEventDto>> Function() load;

  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;
  final Future<void> Function(String url)? onOpenUrl;
  final String emptyText;

  /// 只展示前 N 条(「我的」页只放 3 条预览, 查看全部进用户主页)
  final int? maxItems;

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<rust.FeedEventDto>>(
      load: load,
      emptyText: emptyText,
      keepAlive: true,
      builder: (context, events, reload) {
        final limit = maxItems;
        final shown = limit == null || events.length <= limit
            ? events
            : events.sublist(0, limit);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _EventSummaryCard(
                event: shown[i],
                onPlaySongs: onPlaySongs,
                onOpenUrl: onOpenUrl,
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 一条动态的列表摘要(卡片): 类型 + 时间 / 正文或标题 / 互动计数.
///
/// 关注流里的完整卡片(feed_view 的 _FeedCard)带配图/视频/点赞按钮, 体量大且是
/// 私有实现; 用户主页/「我的」页只要"看得见有什么动态 + 点进详情", 所以这里用一份
/// 摘要版, 点击统一进 [showFeedDetail]。
class _EventSummaryCard extends StatelessWidget {
  const _EventSummaryCard({
    required this.event,
    this.onPlaySongs,
    this.onOpenUrl,
  });

  final rust.FeedEventDto event;
  final void Function(List<rust.SongDto> songs, int index)? onPlaySongs;
  final Future<void> Function(String url)? onOpenUrl;

  static const Map<String, IconData> _kindIcons = {
    'song': Icons.music_note,
    'playlist': Icons.queue_music,
    'album': Icons.album_outlined,
    'program': Icons.podcasts,
    'text': Icons.article_outlined,
  };

  String get _body {
    final title = event.title.trim();
    if (title.isNotEmpty) return title;
    final text = event.text.trim();
    if (text.isNotEmpty) return text;
    return event.song?.name ?? '';
  }

  String get _counts => [
    if (event.likedCount > BigInt.zero) '赞 ${event.likedCount}',
    if (event.commentCount > BigInt.zero) '评论 ${event.commentCount}',
    if (event.shareCount > BigInt.zero) '转发 ${event.shareCount}',
  ].join(' · ');

  Future<void> _openDetail(BuildContext context) {
    final play = onPlaySongs;
    return showFeedDetail(
      context,
      event: event,
      onPlaySongs:
          play ?? (_, _) => showToast(context, '当前页面不支持播放'),
      onOpenUrl: onOpenUrl ?? PlatformBridge.openUrl,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final body = _body;
    final counts = _counts;
    return Card(
      margin: kCardMargin,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openDetail(context),
        child: Padding(
          padding: const EdgeInsets.all(kPagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    _kindIcons[event.kind] ?? Icons.article_outlined,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    feedKindLabels[event.kind] ?? '动态',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    feedRelativeTime(event.timeMs),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              if (body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  // 长正文走统一长文字组件(需求 5): 3 行截断, 详情页看全文
                  child: AdaptiveText(
                    body,
                    mode: AdaptiveTextMode.wrap,
                    maxLines: 3,
                  ),
                ),
              if (counts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    counts,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 打开他人主页(签名保持兼容: 只新增可选参数)。
Future<void> showUserPage(
  BuildContext context, {
  required BigInt userId,
  String? fallbackNickname,
  void Function(List<rust.SongDto> songs, int index)? onPlaySongs,
  Future<rust.ProfileDetail> Function(BigInt uid)? loadProfile,
  Future<List<rust.Playlist>> Function(BigInt uid)? loadPlaylists,
  UserListLoader? loadFollows,
  UserListLoader? loadFolloweds,
  VoidCallback? onOpenFollows,
  VoidCallback? onOpenFolloweds,
  Future<List<rust.FeedEventDto>> Function(BigInt uid)? loadEvents,
  Future<void> Function(String url)? onOpenUrl,
  String? initialTab,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => UserPage(
        userId: userId,
        fallbackNickname: fallbackNickname,
        onPlaySongs: onPlaySongs,
        loadProfile: loadProfile,
        loadPlaylists: loadPlaylists,
        loadFollows: loadFollows,
        loadFolloweds: loadFolloweds,
        onOpenFollows: onOpenFollows,
        onOpenFolloweds: onOpenFolloweds,
        loadEvents: loadEvents,
        onOpenUrl: onOpenUrl,
        initialTab: initialTab,
      ),
    ),
  );
}
