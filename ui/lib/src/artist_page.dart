import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'cover_art.dart';
import 'error_views.dart';
import 'layout.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'profile_banner.dart';
import 'profile_scaffold.dart';
import 'rust/api.dart' as rust;
import 'toast.dart';
import 'song_actions.dart';
import 'format.dart' show formatDurationMs;
import 'mv_page.dart' show showMvPage;
import 'song_tile.dart' show SongTitleWithBadges;
import 'state_views.dart';
import 'artist_sections.dart'
    show ArtistAlbumsSection, ArtistRecommendedSongsSection;
import 'expandable_text.dart';

/// 艺人详情页(C1 重构): 顶部信息区(横幅/头像/姓名/统计/简介/关注) + Tab
/// (全部歌曲 / 专辑(有才显示) / MV(有才显示)) + 页内搜索(只过滤「全部歌曲」)。
/// 与用户个人主页区分的丰富区块: 简介 / 推荐单曲(top5) / 专辑横滑 / 详细艺人弹层。
/// 相似艺人在信息区尾部(胶囊 Wrap, 防溢出), 弹层里也有一份。
/// 动态 tab 未实现: vendor 没有"艺人动态"接口(见 docs/c1-artist-page-notes.md)。
/// 打开方式: [showArtistDetail], 全屏 MaterialPageRoute。
Future<void> showArtistDetail(
  BuildContext context, {
  required BigInt artistId,
  String? name,
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum,
  Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist, // 测试注入
  Future<List<rust.Artist>> Function(BigInt)? loadSimilar, // 测试注入
  Future<rust.ArtistSongPageDto> Function(BigInt, int offset)?
  loadSongsPage, // 测试注入
  Future<rust.ArtistMvPageDto> Function(BigInt, int offset)?
  loadMvsPage, // 测试注入
  Future<bool> Function(BigInt, bool sub)? toggleFollow, // 测试注入
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ArtistDetailPage(
        artistId: artistId,
        name: name,
        onPlaySongs: onPlaySongs,
        onOpenAlbum: onOpenAlbum,
        loadArtist: loadArtist,
        loadSimilar: loadSimilar,
        loadSongsPage: loadSongsPage,
        loadMvsPage: loadMvsPage,
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
    this.loadArtist,
    this.loadSimilar,
    this.loadSongsPage,
    this.loadMvsPage,
    this.loadAlbumsPage,
    this.toggleFollow,
  });

  final BigInt artistId;
  final String? name;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum;
  final Future<rust.ArtistDetailDto> Function(BigInt)? loadArtist;
  final Future<List<rust.Artist>> Function(BigInt)? loadSimilar;
  final Future<rust.ArtistSongPageDto> Function(BigInt, int offset)?
  loadSongsPage;
  final Future<rust.ArtistMvPageDto> Function(BigInt, int offset)? loadMvsPage;

  /// 专辑分页(offset/limit)。缺省走 artist_albums_page: 详情只带 20 张,
  /// 头部 albumSize 才是真实总数, 专辑 tab 必须能翻完。
  final Future<rust.ArtistAlbumPageDto> Function(
    BigInt artistId,
    int offset,
    int limit,
  )?
  loadAlbumsPage;
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

  /// 页内搜索(就地过滤歌曲类 tab, 不发请求)
  bool _searching = false;
  String _query = '';

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

  /// 切到指定 tab(推荐单曲/专辑区块的「查看全部」入口用);
  /// 目标 tab 可能因数据未到而不存在, 此时静默不动。
  void _switchToTab(_TabKind kind) {
    final index = _tabs.indexOf(kind);
    if (index < 0) return;
    // 注意: 「查看全部歌曲」的目标 tab 恒为 index 0, 常常**就是当前 tab**,
    // 旧实现里 `index != _tabController.index` 的 guard 会直接吞掉这次点击
    // ⇒ 用户点了没反应。这里改成: 先切 index, 再无条件滚到 TabBar 之后的内容区。
    if (_tabController.index != index) {
      _tabController.index = index;
    }
    // 只改 index 不滚动: 用户停在「信息区」时 TabBarView 的内容在折线以下,
    // 视觉上同样是「点了没反应」。收起横幅, 露出 tab 内容。
    final scroll = _scroll;
    if (scroll.hasClients &&
        scroll.offset < scroll.position.maxScrollExtent - 1) {
      scroll.animateTo(
        scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
  }

  List<_TabKind> get _tabs => [
    _TabKind.allSongs,
    if (_detail?.albums.isNotEmpty ?? false) _TabKind.albums,
    if (_mvsFirstPage?.isNotEmpty ?? false) _TabKind.mvs,
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
      setState(() => _detail = detail);
      _rebuildTabs();
      _loadMvsAvailability();
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
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, friendlyError(e));
    }
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
      actions: [
        IconButton(
          icon: Icon(_searching ? Icons.close : Icons.search),
          tooltip: '搜索该艺人歌曲',
          onPressed: () => setState(() {
            _searching = !_searching;
            if (!_searching) _query = '';
          }),
        ),
      ],
      banner: _buildBanner(theme, detail),
      // 身份卡(头像/名字/别名/统计 chip): 横幅之下, 不压图
      identity: _buildIdentity(detail),
      // 共享信息区: 简介/推荐单曲/专辑/相似艺人/详细艺人(TabBar 之上)
      sections: _buildInfoSections(theme, detail),
      searchBar: _searching ? _buildSearchBar(theme) : null,
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
      case _TabKind.allSongs:
        return _AllSongsTab(
          artistId: widget.artistId,
          query: _query,
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
    }
  }

  /// 横幅: 只有封面图 + 底部轻渐变(文字已移到图下方的身份卡, 不再压图)
  Widget _buildBanner(ThemeData theme, rust.ArtistDetailDto detail) {
    return ProfileBannerImage(url: detail.coverUrl);
  }

  /// pinned 页内搜索条(只过滤「全部歌曲」tab, 不发请求; 高度由骨架定)。
  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        autofocus: true,
        controller: TextEditingController(text: _query)
          ..selection = TextSelection(
            baseOffset: 0,
            extentOffset: _query.length,
          ),
        onChanged: (v) => setState(() => _query = v),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索该艺人的歌曲',
          prefixIcon: const Icon(Icons.search, size: 20),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(24)),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
        ),
        style: theme.textTheme.bodyMedium,
      ),
    );
  }

  /// 身份卡: 头像/名字/别名 + 统计 chip(作品数) + 关注按钮。
  ///
  /// 统计行(footer)只放**统计与入口**, 与用户页的 关注/粉丝/等级 同一套 chip;
  /// 「关注」是写操作, 放 [ProfileIdentity.trailing]: 之前它和统计 chip 长得一样,
  /// 用户无法从外观判断点了是"发请求关注"还是"打开关注列表"。
  /// 作品数为 0 时整行不渲染(缺的条目不显示, 不留 "0 个专辑 · 0 首歌曲")。
  Widget _buildIdentity(rust.ArtistDetailDto detail) {
    final followed = _followed ?? false;
    final hasWorks =
        detail.albumCount > BigInt.zero || detail.musicCount > BigInt.zero;
    return ProfileIdentity(
      title: detail.name,
      subtitle: detail.alias.isEmpty ? null : detail.alias.join(' / '),
      avatarUrl: detail.avatarUrl,
      footer: hasWorks
          ? ProfileStatRow(
              chips: [
                ProfileWorksStatChip(
                  albumCount: detail.albumCount,
                  songCount: detail.musicCount,
                ),
              ],
            )
          : null,
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
  /// 顺序与用户页同一口径(见 profile_scaffold.dart 文件头): 简介 → 作品
  /// (推荐单曲/专辑) → 相似艺人。相似艺人是纯跳转入口, 放最后, 不挡作品。
  /// 每块都走 [ProfileSection](标题风格/块间 16 只定义一次), 空分区整块不渲染。
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
      if (detail.songs.isNotEmpty)
        ProfileSection(
          child: ArtistRecommendedSongsSection(
            songs: detail.songs.take(5).toList(),
            totalCount: detail.musicCount,
            onPlaySongs: widget.onPlaySongs,
            onSeeAll: () => _switchToTab(_TabKind.allSongs),
          ),
        ),
      if (detail.albums.isNotEmpty)
        ProfileSection(
          child: ArtistAlbumsSection(
            albums: detail.albums.take(6).toList(),
            totalCount: detail.albumCount,
            onOpenAlbum: widget.onOpenAlbum,
            onSeeAll: () => _switchToTab(_TabKind.albums),
          ),
        ),
      // 相似艺人(未登录/接口不支持时整块不渲染)
      if (_similar.isNotEmpty)
        ProfileSection(title: '相似艺人', child: _buildSimilarArtists(theme)),
      // 「详细艺人资料」入口已移除: 弹层里只有统计/简介/相似艺人三块,
      // 而这三块在本页上方都已各自渲染, 用户反馈"不知所云"(见 analysis/artist.md §5)。
    ];
  }

  /// 相似艺人: 头像 + 名字的小胶囊(Wrap 防溢出, 名字单行省略)
  Widget _buildSimilarArtists(ThemeData theme) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final a in _similar)
          ActionChip(
            avatar: CircleCover(url: a.avatarUrl, size: 24),
            // 单行 + ellipsis: 300dp + textScale 1.25 也不溢出
            // (MarqueeText 正在被另一车道修测量 bug, 这里不用)
            label: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            onPressed: () => showArtistDetail(
              context,
              artistId: a.id,
              name: a.name,
              onPlaySongs: widget.onPlaySongs,
              onOpenAlbum: widget.onOpenAlbum,
            ),
          ),
      ],
    );
  }
}

enum _TabKind {
  allSongs('全部歌曲'),
  albums('专辑'),
  mvs('MV');

  const _TabKind(this.label);
  final String label;
}

/// 全部歌曲 tab: offset/limit 分页(PagedListView); 有搜索词时改为
/// 聚合拉取(最多 _searchCap 条)后本地过滤。
class _AllSongsTab extends StatefulWidget {
  const _AllSongsTab({
    required this.artistId,
    required this.query,
    required this.loader,
    required this.onPlaySongs,
  });

  final BigInt artistId;
  final String query;
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

  @override
  void initState() {
    super.initState();
    _runQuery();
  }

  @override
  void didUpdateWidget(covariant _AllSongsTab old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) _runQuery();
  }

  Future<void> _runQuery() async {
    final q = widget.query.trim();
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
    final q = widget.query.trim();
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
      gridDelegate: coverGridDelegate(
        context,
        columns: AppSettings.instance.gridColumns,
        crossAxisSpacing: 10,
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
