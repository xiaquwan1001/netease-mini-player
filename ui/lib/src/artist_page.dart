import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'app_settings.dart';
import 'cover_art.dart';
import 'error_views.dart';
import 'feed_media.dart'
    show FeedImageGrid, FeedSongMiniCard, FeedVideoThumb, feedAttachedImages;
import 'feed_detail_page.dart'
    show showFeedDetail, feedRelativeTime, feedKindLabels;
import 'layout.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'profile_banner.dart';
import 'profile_scaffold.dart';
import 'rust/api.dart' as rust;
import 'toast.dart';
import 'song_actions.dart';
import 'format.dart' show formatDurationMs, formatFanCount;
import 'mv_page.dart' show showMvPage;
import 'song_tile.dart' show SongTitleWithBadges;
import 'state_views.dart';
import 'artist_sections.dart'
    show ArtistRecommendedSongsSection, SimilarArtistsRow;
import 'expandable_text.dart';

/// 艺人详情页(C1 重构): 顶部信息区(横幅/头像/姓名/作品数/简介/关注) + 纵向 tab。
///
/// 信息区(横幅之下、TabBar 之上)只剩两块, 其余全部下沉成 tab(需求 13):
///   简介(有才显示) → 相似艺人(有才显示, 横排可拖拽)
///
/// tab 集合由**数据可用性**生成, 顺序固定:
///   推荐单曲(有才显示) / 全部歌曲 / 专辑(有专辑) / MV(有 MV) / 动态(有动态)
/// 每个 tab 是同一批数据**唯一**的渲染位置 —— 信息区不再重复渲染推荐单曲与专辑横滑,
/// 因此也不再有「查看全部」跳 tab 的二次入口(点一次就到的内容不需要两次点击)。
///
/// 页内搜索只过滤「全部歌曲」tab。
/// 打开方式: [showArtistDetail], 全屏 MaterialPageRoute。
Future<void> showArtistDetail(
  BuildContext context, {
  required BigInt artistId,
  String? name,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum,

  /// 动态 tab 里点视频/外链时用; 不注入则只提示(桌面/测试可省略)
  Future<void> Function(String url)? onOpenUrl,
  Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist, // 测试注入
  Future<List<rust.Artist>> Function(BigInt)? loadSimilar, // 测试注入
  Future<rust.ArtistSongPageDto> Function(BigInt, int offset)?
  loadSongsPage, // 测试注入
  Future<rust.ArtistMvPageDto> Function(BigInt, int offset)?
  loadMvsPage, // 测试注入
  Future<List<rust.FeedEventDto>> Function(BigInt)? loadDynamics, // 测试注入
  Future<bool> Function(BigInt, bool sub)? toggleFollow, // 测试注入
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ArtistDetailPage(
        artistId: artistId,
        name: name,
        onPlaySongs: onPlaySongs,
        onOpenAlbum: onOpenAlbum,
        onOpenUrl: onOpenUrl,
        loadArtist: loadArtist,
        loadSimilar: loadSimilar,
        loadSongsPage: loadSongsPage,
        loadMvsPage: loadMvsPage,
        loadDynamics: loadDynamics,
        toggleFollow: toggleFollow,
      ),
    ),
  );
}

class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({
    super.key,
    required this.artistId,
    required this.onPlaySongs,
    this.name,
    this.onOpenAlbum,
    this.onOpenUrl,
    this.loadArtist,
    this.loadSimilar,
    this.loadSongsPage,
    this.loadMvsPage,
    this.loadAlbumsPage,
    this.loadDynamics,
    this.toggleFollow,
  });

  final BigInt artistId;
  final String? name;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum;

  /// 动态 tab 里打开外链(视频直链等); 空则提示不支持
  final Future<void> Function(String url)? onOpenUrl;
  final Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist;
  final Future<List<rust.Artist>> Function(BigInt)? loadSimilar;
  final Future<rust.ArtistSongPageDto> Function(BigInt, int offset)?
  loadSongsPage;
  final Future<rust.ArtistMvPageDto> Function(BigInt, int offset)? loadMvsPage;

  /// 专辑分页(offset/limit)。缺省走 artist_albums_page: 详情只带 20 张,
  /// 头部 albumCount 才是真实总数, 专辑 tab 必须能翻完。
  final Future<rust.ArtistAlbumPageDto> Function(
    BigInt artistId,
    int offset,
    int limit,
  )?
  loadAlbumsPage;

  /// 艺人动态(需求 13 的「动态」tab): 非空列表才生成 tab。
  /// 缺省走 rust.userEvents(尽力而为: 拿不到/空列表就不显示 tab, 不报错)。
  final Future<List<rust.FeedEventDto>> Function(BigInt)? loadDynamics;
  final Future<bool> Function(BigInt, bool sub)? toggleFollow;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage>
    with TickerProviderStateMixin {
  rust.ArtistDetailDto? _detail;
  String? _error;

  /// 相似艺人(需要登录; 拿不到就整块不显示, 不打扰其它内容)
  List<rust.Artist> _similar = const [];

  /// MV tab 数据可用性: 探测第一页, 非空才显示 tab(空 = 不显示)。
  List<rust.ArtistMvDto>? _mvsFirstPage;
  bool _mvsHasMore = false;

  /// 动态 tab 数据可用性: 探测第一页, 非空才显示 tab。
  List<rust.FeedEventDto>? _dynamics;

  late TabController _tabController = TabController(length: 0, vsync: this);

  /// 关注状态(接口不回传初始值, 本地乐观维护)
  bool? _followed;
  final ScrollController _scroll = ScrollController();
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
    _loadSimilar();
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

  Future<rust.ArtistSongPageDto> _defaultSongsPage(BigInt id, int offset) =>
      retryNetwork(
        () => rust.artistSongsPage(artistId: id, offset: offset, limit: 60),
      );

  Future<rust.ArtistMvPageDto> _defaultMvsPage(BigInt id, int offset) =>
      retryNetwork(
        () => rust.artistMvsPage(artistId: id, offset: offset, limit: 20),
      );

  Future<rust.ArtistAlbumPageDto> _defaultAlbumsPage(
    BigInt id,
    int offset,
    int limit,
  ) => retryNetwork(
    () => rust.artistAlbumsPage(artistId: id, offset: offset, limit: limit),
  );

  Future<rust.ArtistAlbumPageDto> Function(BigInt, int, int)
  get _albumsLoader => widget.loadAlbumsPage ?? _defaultAlbumsPage;

  Future<rust.ArtistSongPageDto> Function(BigInt, int) get _songsLoader =>
      widget.loadSongsPage ?? _defaultSongsPage;
  Future<rust.ArtistMvPageDto> Function(BigInt, int) get _mvsLoader =>
      widget.loadMvsPage ?? _defaultMvsPage;

  Future<void> _loadMvsAvailability() async {
    try {
      final page = await _mvsLoader(widget.artistId, 0);
      if (!mounted) return;
      setState(() {
        _mvsFirstPage = page.mvs;
        _mvsHasMore = page.hasMore;
      });
      _rebuildTabs();
    } catch (_) {
      // MV 拿不到: 不显示 MV tab
    }
  }

  /// 艺人动态探测: 拿不到/空列表就不生成「动态」tab(需求 13: 有数据才显示)。
  ///
  /// **必须用艺人绑定的用户账号 id(userId), 不能用 artistId**:
  /// artistId 与 userId 是两套 id(周杰伦主条目 6452 根本没有绑定账号),
  /// 过去拿 artistId 当 uid 请求, 服务端要么忽略 uid 返回自己的关注流,
  /// 要么返回空列表 —— 前者正是"艺人页动态内容是我自己的动态"的原因(用户反馈 11)。
  /// 没有绑定账号 ⇒ 官方没有合法的动态来源, 直接不生成 tab。
  Future<void> _loadDynamicsAvailability(rust.ArtistDetailDto detail) async {
    final uid = detail.userId;
    if (uid == null || uid == BigInt.zero) {
      // 无绑定账号: 明确不显示动态 tab(而不是显示别人的动态)
      if (_dynamics != null && mounted) {
        setState(() => _dynamics = null);
        _rebuildTabs();
      }
      return;
    }
    try {
      final list = await (widget.loadDynamics != null
          ? widget.loadDynamics!(uid)
          : rust.userEvents(uid: uid, limit: 10, lastTime: -1));
      if (!mounted) return;
      setState(() => _dynamics = list);
      _rebuildTabs();
    } catch (_) {
      // 没有动态(或接口不可用): 不显示 tab
    }
  }

  /// tab 集合变了就换新 controller(旧的一律延到帧末 dispose, 见
  /// [syncProfileTabs] —— 立刻 dispose 会抛 used-after-dispose)。
  void _rebuildTabs() {
    _tabController = syncProfileTabs(
      vsync: this,
      current: _tabController,
      length: _tabs.length,
      onChanged: () => setState(() {}),
    );
  }

  /// 声明式 tab: 每个 [_TabKind] 对应一条 [ProfileTabSpec], 内容懒构建。
  List<ProfileTabSpec> _tabSpecs(rust.ArtistDetailDto detail) => [
    for (final kind in _tabs)
      ProfileTabSpec(
        kind.label,
        builder: (context) => _buildTab(kind, context, detail),
      ),
  ];

  /// tab 顺序固定(需求 13): 推荐单曲 → 全部歌曲 → 专辑 → MV → 动态。
  /// 「全部歌曲」恒在(艺人一定可以查歌曲列表), 其余按数据可用性出现。
  List<_TabKind> get _tabs => [
    if (_detail?.songs.isNotEmpty ?? false) _TabKind.recommended,
    _TabKind.allSongs,
    if (_detail?.albums.isNotEmpty ?? false) _TabKind.albums,
    if (_mvsFirstPage?.isNotEmpty ?? false) _TabKind.mvs,
    if (_dynamics?.isNotEmpty ?? false) _TabKind.dynamics,
  ];

  Future<void> _loadSimilar() async {
    try {
      final list = await (widget.loadSimilar != null
          ? widget.loadSimilar!(widget.artistId)
          : retryNetwork(() => rust.similarArtists(artistId: widget.artistId)));
      if (!mounted) return;
      setState(() => _similar = list);
    } catch (_) {
      // 未登录/接口不支持: 静默隐藏
    }
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
    });
    try {
      final detail = widget.loadArtist != null
          ? await widget.loadArtist!(widget.artistId)
          : await retryNetwork(
              () => rust.artistDetail(artistId: widget.artistId),
            );
      if (!mounted) return;
      setState(() {
        _detail = detail;
        // 关注态来自 artist/follow/count/get 的 isFollow: 不再"恒为未关注"
        _followed = detail.followed;
      });
      _rebuildTabs();
      _loadMvsAvailability();
      _loadDynamicsAvailability(detail);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    }
  }

  Future<void> _toggleFollow() async {
    if (_detail == null) return;
    final next = !(_followed ?? false);
    try {
      final ok = await (widget.toggleFollow != null
          ? widget.toggleFollow!(widget.artistId, next)
          : retryNetwork(
              () => rust.artistSubToggle(artistId: widget.artistId, sub: next),
            ));
      if (!mounted) return;
      if (ok) {
        setState(() => _followed = next);
        // 取消关注只给 3 秒提示: 关注按钮就在旁边, 再点一次即可恢复
        // (用户反馈撤销条常驻遮挡内容)
        if (!next) {
          final name = widget.name ?? _detail?.name ?? '';
          showToast(context, '已取消关注${name.isEmpty ? '' : ' $name'}');
        }
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, friendlyError(e));
    }
  }

  /// 动态 tab 里的外链(视频直链): 注入方负责打开; 未注入时提示, 不静默吞掉点击
  Future<void> _openUrl(String url) async {
    final open = widget.onOpenUrl;
    if (open == null) {
      showToast(context, '暂不支持在当前版本打开动态外链');
      return;
    }
    await open(url);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_detail == null && _error == null) {
      return const Scaffold(body: LoadingView());
    }
    if (_error != null) {
      // 与用户页同一份首屏错误形态(之前一边是红字 + 按钮, 一边是 Card/ListTile)
      return ProfileLoadError(
        title: widget.name ?? _detail?.name ?? '艺人详情',
        message: _error!,
        onRetry: _load,
      );
    }
    final detail = _detail!;
    final artistName = widget.name ?? detail.name;
    return ProfileScaffold(
      scrollController: _scroll,
      // 收起时顶栏保留艺人名; 展开时横幅里已有名字, 顶栏不重复
      collapsedTitle: _collapsed ? artistName : null,
      banner: _buildBanner(theme, detail),
      // 身份卡(头像/名字/别名/作品数): 横幅之下, 不压图
      identity: _buildIdentity(detail),
      // 共享信息区: 简介 / 相似艺人(TabBar 之上); 推荐单曲与专辑横滑已下沉成 tab
      sections: _buildInfoSections(theme, detail),
      tabs: _tabSpecs(detail),
      controller: _tabController,
    );
  }

  Widget _buildTab(
    _TabKind kind,
    BuildContext context,
    rust.ArtistDetailDto detail,
  ) {
    switch (kind) {
      case _TabKind.recommended:
        return ListView(
          padding: EdgeInsets.fromLTRB(
            kPagePadding,
            12,
            kPagePadding,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            ArtistRecommendedSongsSection(
              songs: detail.songs,
              onPlaySongs: widget.onPlaySongs,
            ),
          ],
        );
      case _TabKind.allSongs:
        return _AllSongsTab(
          artistId: widget.artistId,
          totalCount: detail.musicCount,
          loader: _songsLoader,
          onPlaySongs: widget.onPlaySongs,
        );
      case _TabKind.albums:
        return _AlbumsTab(
          artistId: widget.artistId,
          load: _albumsLoader,
          onOpenAlbum: widget.onOpenAlbum,
        );
      case _TabKind.mvs:
        return _MvsTab(
          artistId: widget.artistId,
          firstPage: _mvsFirstPage ?? const [],
          firstPageHasMore: _mvsHasMore,
          loader: _mvsLoader,
        );
      case _TabKind.dynamics:
        return _DynamicsTab(
          events: _dynamics ?? const [],
          onPlaySongs: widget.onPlaySongs,
          onOpenUrl: _openUrl,
        );
    }
  }

  /// 横幅: 只有封面图 + 底部轻渐变(文字已移到图下方的身份卡, 不再压图)
  Widget _buildBanner(ThemeData theme, rust.ArtistDetailDto detail) {
    return ProfileBannerImage(url: detail.coverUrl);
  }

  /// 身份卡: 头像/名字/别名 + 统计行(footer, 整卡宽) + 关注按钮。
  ///
  /// 统计行放 [ProfileIdentity.footer] 而不是 [ProfileIdentity.meta]:
  /// meta 在头像右侧的文字列里, 宽度被头像 + 关注按钮挤掉, 实测窄屏上
  /// 「32 个专辑 · 379 首歌曲 · 1922.7万粉丝」会被省略号截断(用户反馈
  /// 「横条左右宽度不够导致数字被遮挡」)。footer 占整卡宽度, 用 Wrap 换行,
  /// 数字完整可读; 粉丝数来自 artist/follow/count/get 的 fansCnt(0 = 不渲染)。
  Widget _buildIdentity(rust.ArtistDetailDto detail) {
    final followed = _followed ?? false;
    final hasWorks =
        detail.albumCount > BigInt.zero || detail.musicCount > BigInt.zero;
    final chips = <Widget>[
      if (detail.fansCount > BigInt.zero)
        ProfileStatChip(
          icon: Icons.people_outline,
          label: '粉丝 ${formatFanCount(detail.fansCount)}',
        ),
      if (hasWorks)
        ProfileWorksStatChip(
          albumCount: detail.albumCount,
          songCount: detail.musicCount,
        ),
    ];
    return ProfileIdentity(
      title: detail.name,
      subtitle: detail.alias.isEmpty ? null : detail.alias.join(' / '),
      avatarUrl: detail.avatarUrl,
      footer: chips.isEmpty ? null : ProfileStatRow(chips: chips),
      // 关注状态为乐观更新(接口成功才翻转)
      trailing: FilledButton.tonal(
        onPressed: _toggleFollow,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          padding: const EdgeInsets.symmetric(horizontal: 12),
        ),
        child: Text(followed ? '已关注' : '关注'),
      ),
    );
  }

  /// 信息区(横幅之下、TabBar 之上的共享内容)。
  ///
  /// 只剩两块(需求 13): 简介 → 相似艺人。推荐单曲/专辑横滑已下沉成 tab,
  /// 信息区不再重复渲染同一批数据。每块都走 [ProfileSection](标题风格/块间 16),
  /// 空分区整块不渲染。
  List<Widget> _buildInfoSections(
    ThemeData theme,
    rust.ArtistDetailDto detail,
  ) {
    return [
      if (detail.briefDesc.trim().isNotEmpty)
        ProfileSection(
          title: '简介',
          child: ExpandableText(text: detail.briefDesc),
        ),
      // 相似艺人(未登录/接口不支持时整块不渲染): 横排可拖拽, 不做自动滚动
      if (_similar.isNotEmpty)
        ProfileSection(
          title: '相似艺人',
          child: SimilarArtistsRow(
            artists: _similar,
            onOpen: (a) => showArtistDetail(
              context,
              artistId: a.id,
              name: a.name,
              onPlaySongs: widget.onPlaySongs,
              onOpenAlbum: widget.onOpenAlbum,
              onOpenUrl: widget.onOpenUrl,
              loadDynamics: widget.loadDynamics,
            ),
          ),
        ),
    ];
  }
}

enum _TabKind {
  recommended('推荐单曲'),
  allSongs('全部歌曲'),
  albums('专辑'),
  mvs('MV'),
  dynamics('动态');

  const _TabKind(this.label);
  final String label;
}

/// 动态 tab: 艺人动态列表(只有拿到数据时这个 tab 才存在)。
/// 点一行进动态详情页(正文/配图/视频/评论全部复用 feed_detail_page)。
class _DynamicsTab extends StatelessWidget {
  const _DynamicsTab({
    required this.events,
    required this.onPlaySongs,
    required this.onOpenUrl,
  });

  final List<rust.FeedEventDto> events;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final Future<void> Function(String url) onOpenUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (events.isEmpty) {
      return const EmptyView(icon: Icons.dynamic_feed_outlined, title: '暂无动态');
    }
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        kPagePadding,
        12,
        kPagePadding,
        24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: events.length,
      itemBuilder: (context, i) {
        final e = events[i];
        final body = e.title.trim().isNotEmpty ? e.title.trim() : e.text.trim();
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => showFeedDetail(
            context,
            event: e,
            onPlaySongs: onPlaySongs,
            onOpenUrl: onOpenUrl,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 长文走 AdaptiveText(单行跑马灯); 这里允许 3 行换行
                AdaptiveText(
                  body.isEmpty ? '（无正文）' : body,
                  mode: AdaptiveTextMode.wrap,
                  maxLines: 3,
                  style: theme.textTheme.bodyMedium,
                ),

                // 需求: 艺人页「动态」tab 与关注动态流同一口径 —— 附图/分享的
                // 单曲/视频都直接展示, 不必点进详情(与 feed_view/用户主页共用组件)
                if (feedAttachedImages(e).isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FeedImageGrid(images: feedAttachedImages(e)),
                  ),
                if (e.song != null)
                  FeedSongMiniCard(
                    song: e.song!,
                    coverUrl: e.coverUrl,
                    onPlaySongs: onPlaySongs,
                  ),
                if (e.videoUrl != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FeedVideoThumb(
                      url: e.videoUrl!,
                      coverUrl: e.coverUrl,
                      onOpenUrl: onOpenUrl,
                    ),
                  ),
                const SizedBox(height: 4),
                Text(
                  [
                    feedRelativeTime(e.timeMs),
                    feedKindLabels[e.kind] ?? '动态',
                    if (e.commentCount > BigInt.zero) '${e.commentCount} 评论',
                    if (e.likedCount > BigInt.zero) '${e.likedCount} 赞',
                  ].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.outline,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 全部歌曲 tab: 头部「共 N 首 + 搜索」, 下面是 offset/limit 分页(PagedListView);
/// 打开搜索后改为聚合拉取(最多 _searchCap 条)再本地过滤。
///
/// 搜索入口与「共 N 首」都落在**这一条 tab 自己的头部**里:
/// 之前搜索图标挂在顶栏右上角(压在横幅图上, 容易被背景色吃掉), 「共 N 首」
/// 挂在推荐单曲 tab 的标题行右侧 —— 两处都不属于它们表达的内容(用户反馈 2/3)。
class _AllSongsTab extends StatefulWidget {
  const _AllSongsTab({
    required this.artistId,
    required this.totalCount,
    required this.loader,
    required this.onPlaySongs,
  });

  final BigInt artistId;

  /// 全量歌曲数(artist detail 的 musicSize), 头部「共 N 首」用
  final BigInt totalCount;
  final Future<rust.ArtistSongPageDto> Function(BigInt, int) loader;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;

  @override
  State<_AllSongsTab> createState() => _AllSongsTabState();
}

class _AllSongsTabState extends State<_AllSongsTab> {
  /// 搜索时聚合全量(最多 _searchCap 条)后本地过滤
  static const _searchCap = 600;
  static const _pageSize = 60;

  List<rust.SongDto>? _searchResults;
  bool _searching = false;
  String? _searchError;
  String? _ranQuery;

  /// 搜索框是否展开(搜索图标在「共 N 首」右侧, 点开才显示输入框)
  bool _searchOpen = false;
  String _query = '';
  final TextEditingController _ctrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _runQuery();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _ctrl.clear();
        _query = '';
      }
    });
    _runQuery();
  }

  Future<void> _runQuery() async {
    final q = _query.trim();
    if (q.isEmpty) {
      setState(() {
        _searchResults = null;
        _searchError = null;
        _ranQuery = null;
      });
      return;
    }
    setState(() {
      _searching = true;
      _searchError = null;
      _ranQuery = q;
    });
    try {
      final out = <rust.SongDto>[];
      var offset = 0;
      var hasMore = true;
      while (hasMore && offset < _searchCap) {
        final page = await widget.loader(widget.artistId, offset);
        for (final s in page.songs) {
          if (s.name.toLowerCase().contains(q.toLowerCase()) ||
              s.artist.toLowerCase().contains(q.toLowerCase())) {
            out.add(s);
          }
        }
        hasMore = page.hasMore;
        offset += page.songs.length;
      }
      if (!mounted) return;
      setState(() {
        _searchResults = out;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchError = friendlyError(e);
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kPagePadding, 8, kPagePadding, 0),
          child: Row(
            children: [
              Text(
                '共 ${widget.totalCount} 首',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(_searchOpen ? Icons.close : Icons.search),
                tooltip: _searchOpen ? '关闭搜索' : '搜索该艺人的歌曲',
                visualDensity: VisualDensity.compact,
                onPressed: _toggleSearch,
              ),
            ],
          ),
        ),
        if (_searchOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              0,
              kPagePadding,
              8,
            ),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              onChanged: (v) {
                setState(() => _query = v);
                _runQuery();
              },
              decoration: InputDecoration(
                isDense: true,
                hintText: '搜索该艺人的歌曲',
                prefixIcon: const Icon(Icons.search, size: 20),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              style: theme.textTheme.bodyMedium,
            ),
          ),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    final q = _query.trim();
    if (q.isEmpty) {
      // 无搜索词: 正常 offset/limit 分页(复用 PagedListView)
      return PagedListView<rust.SongDto>(
        key: ValueKey('all-songs-${widget.artistId}'),
        pageSize: _pageSize,
        keyOf: (s) => s.id,
        emptyText: '暂无歌曲',
        loader: (cursor) => widget
            .loader(widget.artistId, cursor)
            .then((p) => PagedPage(p.songs, hasMore: p.hasMore)),
        itemBuilder: (context, song, index, items) => _ArtistSongRow(
          song: song,
          index: index,
          onTap: () => widget.onPlaySongs(items, index),
        ),
      );
    }
    if (_searching) {
      return const LoadingView();
    }
    if (_searchError != null) {
      // 与用户页 tab 内错误同一形态(行内文案 + 重试)
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: InlineError(message: _searchError!, onRetry: _runQuery),
        ),
      );
    }
    final results = _searchResults ?? const <rust.SongDto>[];
    if (results.isEmpty) {
      return Center(child: Text('没有匹配「$_ranQuery」的歌曲'));
    }
    // 非分页: 搜索结果在本地按 offset 累积到上限(进入即取全), 无游标
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: results.length,
      itemBuilder: (context, i) => _ArtistSongRow(
        song: results[i],
        index: i,
        onTap: () => widget.onPlaySongs(results, i),
      ),
    );
  }
}

/// 专辑 tab: 单页网格(封面 + 名字 + 年份)
class _AlbumsTab extends StatelessWidget {
  const _AlbumsTab({
    required this.artistId,
    required this.load,
    required this.onOpenAlbum,
  });

  final BigInt artistId;

  /// 专辑分页加载(offset/limit)。详情只带前 20 张, 头部 albumSize 才是真实总数,
  /// 过去「全部 N 张」点进来永远只有 20 张(假承诺), 现在滚到底自动续页。
  final Future<rust.ArtistAlbumPageDto> Function(
    BigInt artistId,
    int offset,
    int limit,
  )
  load;

  final void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PagedListView<rust.AlbumBrief>(
      key: ValueKey('artist-albums-$artistId'),
      emptyText: '暂无专辑',
      padding: EdgeInsets.fromLTRB(
        kPagePadding,
        12,
        kPagePadding,
        24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      loader: (cursor) async {
        final page = await load(artistId, cursor, 30);
        return PagedPage(
          page.albums,
          hasMore: page.hasMore,
          nextCursor: cursor + page.albums.length,
        );
      },
      keyOf: (a) => a.id,
      // 列数由设置决定 + 高度按内容算(见 coverGridDelegate), 末端不再留空隙
      gridDelegateBuilder: (context, availableWidth) => coverGridDelegate(
        availableWidth,
        columns: AppSettings.instance.gridColumns,
        crossAxisSpacing: 10,
        textScaler: MediaQuery.textScalerOf(context),
      ),
      itemBuilder: (context, album, i, items) {
        final year = album.publishTime > BigInt.zero
            ? DateTime.fromMillisecondsSinceEpoch(album.publishTime.toInt())
                  .year
            : null;
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onOpenAlbum == null
              ? null
              : () => onOpenAlbum!(album.id, album.name, album.coverUrl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 封面恒为正方形: 之前是 Expanded(CoverArt), 网格高度富余时
              // 会把方图拉成细长条(用户反馈「专辑图片只有细长一条」)。
              AspectRatio(
                aspectRatio: 1,
                child: CoverArt(url: album.coverUrl, radius: 6),
              ),
              const SizedBox(height: 4),
              Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelMedium,
              ),
              Text(
                year != null
                    ? '$year · ${album.trackCount} 首'
                    : '${album.trackCount} 首',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// MV tab: 第一页已预取, 后续用 PagedListView 续页
class _MvsTab extends StatelessWidget {
  const _MvsTab({
    required this.artistId,
    required this.firstPage,
    required this.firstPageHasMore,
    required this.loader,
  });

  final BigInt artistId;
  final List<rust.ArtistMvDto> firstPage;
  final bool firstPageHasMore;
  final Future<rust.ArtistMvPageDto> Function(BigInt, int) loader;

  @override
  Widget build(BuildContext context) {
    if (firstPage.isEmpty) {
      return const EmptyView(icon: Icons.movie_outlined, title: '暂无 MV');
    }
    final theme = Theme.of(context);
    return PagedListView<rust.ArtistMvDto>(
      pageSize: 20,
      keyOf: (m) => m.id,
      emptyText: '暂无 MV',
      loader: firstPageHasMore
          ? (cursor) async {
              if (cursor == 0) {
                return PagedPage(
                  firstPage,
                  hasMore: true,
                  nextCursor: firstPage.length,
                );
              }
              final p = await loader(artistId, cursor);
              return PagedPage(p.mvs, hasMore: p.hasMore);
            }
          : (_) async => PagedPage(firstPage, hasMore: false),
      itemBuilder: (context, mv, index, items) => ListTile(
        onTap: () => showMvPage(context, mvId: mv.id, name: mv.name),
        leading: mv.coverUrl != null
            ? ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: NetImage(
                  url: mv.coverUrl,
                  height: 54,
                  width: 96,
                  fit: BoxFit.cover,
                ),
              )
            : const SizedBox(width: 96, height: 54),
        title: Text(mv.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${formatDurationMs(mv.durationMs)} · 播放 ${mv.playCount} · ${mv.publishTime}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 热门歌曲行: 序号 + 歌名/艺人 + 时长 + SongOverflowButton。无版权灰显。
class _ArtistSongRow extends StatelessWidget {
  const _ArtistSongRow({
    required this.song,
    required this.index,
    required this.onTap,
  });

  final rust.SongDto song;
  final int index;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final grey = TextStyle(color: scheme.outline);
    return InkWell(
      onTap: song.playable ? onTap : null,
      child: Padding(
        // 与同页其它区块的 12dp 对齐(布局审计 #7)
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 歌名 + VIP/付费/无版权标记(标记固定宽度, 不会被歌名挤掉)
                  SongTitleWithBadges(
                    song: song,
                    style: song.playable ? theme.textTheme.bodyMedium : grey,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: song.playable
                          ? scheme.onSurfaceVariant
                          : scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              formatDurationMs(song.durationMs),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline),
            ),
            SongOverflowButton(
              song: song,
              size: 20,
              source: SongActionSource.artist,
            ),
          ],
        ),
      ),
    );
  }
}

// 长文本展开/收起已收敛到 expandable_text.dart(两份私有实现合并)
