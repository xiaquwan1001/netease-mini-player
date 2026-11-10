import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;
import 'song_actions.dart';
import 'format.dart' show formatDurationMs;
import 'mv_page.dart' show showMvPage;

/// 歌手详情页(C1 重构): 顶部信息区(横幅/头像/姓名/统计/简介/关注) + Tab
/// (热门歌曲 / 全部歌曲 / 专辑 / MV(有才显示)) + 页内搜索(过滤歌曲类 tab)。
/// 相似歌手在信息区尾部(胶囊 Wrap, 防溢出)。
/// 动态 tab 未实现: vendor 没有"歌手动态"接口(见 docs/c1-artist-page-notes.md)。
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
  Future<rust.ArtistSongPageDto> Function(BigInt, int offset)? loadSongsPage, // 测试注入
  Future<rust.ArtistMvPageDto> Function(BigInt, int offset)? loadMvsPage, // 测试注入
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
  final Future<bool> Function(BigInt, bool sub)? toggleFollow;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage>
    with TickerProviderStateMixin {
  rust.ArtistDetailDto? _detail;
  String? _error;

  /// 相似歌手(需要登录; 拿不到就整块不显示, 不打扰其它内容)
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
    final collapsed = _scroll.hasClients && _scroll.offset > 90;
    if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
  }

  Future<rust.ArtistSongPageDto> _defaultSongsPage(
    BigInt id,
    int offset,
  ) => retryNetwork(
      () => rust.artistSongsPage(artistId: id, offset: offset, limit: 60),
    );

  Future<rust.ArtistMvPageDto> _defaultMvsPage(BigInt id, int offset) =>
      retryNetwork(
        () => rust.artistMvsPage(artistId: id, offset: offset, limit: 20),
      );

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

  void _rebuildTabs() {
    final old = _tabController.index;
    _tabController.dispose();
    _tabController = TabController(length: _tabs.length, vsync: this)
      ..addListener(() => setState(() {}));
    if (old < _tabs.length) _tabController.index = old;
  }

  List<_TabKind> get _tabs => [
    _TabKind.hotSongs,
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
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_detail == null && _error == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.name ?? _detail?.name ?? '歌手详情')),
        body: Center(
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
        ),
      );
    }
    final detail = _detail!;
    final artistName = widget.name ?? detail.name;
    final tabs = _tabs;
    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        body: NestedScrollView(
          controller: _scroll,
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverAppBar(
              pinned: true,
              expandedHeight: 170,
              // 收起时顶栏保留歌手名; 展开时横幅里已有名字, 顶栏不重复
              title: _collapsed
                  ? Text(
                      artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    )
                  : null,
              actions: [
                IconButton(
                  icon: Icon(_searching ? Icons.close : Icons.search),
                  tooltip: '搜索该歌手歌曲',
                  onPressed: () => setState(() {
                    _searching = !_searching;
                    if (!_searching) _query = '';
                  }),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: _buildBanner(theme, detail),
              ),
            ),
            // 共享信息区: 统计/关注/简介/相似歌手(随页面滚动, TabBar 之上)
            SliverToBoxAdapter(child: _buildInfoSection(theme, detail)),
            if (_searching)
              SliverPersistentHeader(
                pinned: true,
                delegate: _SearchBarDelegate(
                  query: _query,
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabBarDelegate(
                TabBar(
                  controller: _tabController,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [for (final t in tabs) Tab(text: t.label)],
                ),
              ),
            ),
          ],
          body: TabBarView(
            controller: _tabController,
            children: [
              for (final t in tabs) _buildTab(t, theme, detail),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTab(
    _TabKind kind,
    ThemeData theme,
    rust.ArtistDetailDto detail,
  ) {
    switch (kind) {
      case _TabKind.hotSongs:
        return _HotSongsTab(
          songs: detail.songs,
          query: _query,
          onPlaySongs: widget.onPlaySongs,
        );
      case _TabKind.allSongs:
        return _AllSongsTab(
          artistId: widget.artistId,
          query: _query,
          loader: _songsLoader,
          onPlaySongs: widget.onPlaySongs,
        );
      case _TabKind.albums:
        return _AlbumsTab(
          albums: detail.albums,
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

  /// 横幅: 封面 + 底部渐变, 叠加头像/名字/别名/关注按钮
  Widget _buildBanner(ThemeData theme, rust.ArtistDetailDto detail) {
    const bannerHeight = 170.0;
    return SizedBox(
      height: bannerHeight,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 空 url 时不给 NetImage(占位 Icon 尺寸会随 width=infinity 变 NaN)
          if (detail.coverUrl != null && detail.coverUrl!.isNotEmpty)
            NetImage(
              url: detail.coverUrl,
              height: bannerHeight,
              width: double.infinity,
              fit: BoxFit.cover,
            )
          else
            ColoredBox(color: theme.colorScheme.surfaceContainerHighest),
          // 底部渐变保证白字可读
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black54],
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 12,
            right: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                CircleCover(url: detail.avatarUrl, size: 64),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        detail.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (detail.alias.isNotEmpty)
                        Text(
                          detail.alias.join(' / '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 信息区(横幅之下、TabBar 之上的共享内容): 统计行/关注/简介/相似歌手
  Widget _buildInfoSection(ThemeData theme, rust.ArtistDetailDto detail) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${detail.albumCount} 个专辑 · ${detail.musicCount} 首歌曲',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 关注按钮: 状态为乐观更新(接口成功才翻转)
              TextButton.icon(
                onPressed: _toggleFollow,
                icon: Icon(
                  (_followed ?? false) ? Icons.check : Icons.person_add_alt_1,
                  size: 16,
                ),
                label: Text((_followed ?? false) ? '已关注' : '关注'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
            ],
          ),
          if (detail.briefDesc.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            _ExpandableText(text: detail.briefDesc),
          ],
          if (_similar.isNotEmpty) ...[
            const Divider(height: 24),
            Text('相似歌手', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _buildSimilarArtists(theme),
          ],
          const Divider(height: 24),
        ],
      ),
    );
  }

  /// 相似歌手: 头像 + 名字的小胶囊(Wrap 防溢出, 名字单行省略)
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
            label: Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
  hotSongs('热门歌曲'),
  allSongs('全部歌曲'),
  albums('专辑'),
  mvs('MV');

  const _TabKind(this.label);
  final String label;
}

/// pinned 的搜索条
class _SearchBarDelegate extends SliverPersistentHeaderDelegate {
  const _SearchBarDelegate({required this.query, required this.onChanged});

  final String query;
  final ValueChanged<String> onChanged;

  @override
  double get minExtent => 56;

  @override
  double get maxExtent => 56;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: TextField(
        autofocus: true,
        controller: TextEditingController(text: query)
          ..selection = TextSelection(
            baseOffset: 0,
            extentOffset: query.length,
          ),
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索该歌手的歌曲',
          prefixIcon: const Icon(Icons.search, size: 20),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
        ),
        style: theme.textTheme.bodyMedium,
      ),
    );
  }

  @override
  bool shouldRebuild(_SearchBarDelegate oldDelegate) =>
      oldDelegate.query != query;
}

/// pinned 的 TabBar
class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  const _TabBarDelegate(this.tabBar);

  final TabBar tabBar;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => true;
}

/// 热门歌曲 tab: 详情接口带来的 top songs + 页内过滤(不发请求)
class _HotSongsTab extends StatelessWidget {
  const _HotSongsTab({
    required this.songs,
    required this.query,
    required this.onPlaySongs,
  });

  final List<rust.SongDto> songs;
  final String query;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;

  List<rust.SongDto> get _filtered => query.isEmpty
      ? songs
      : songs
            .where(
              (s) =>
                  s.name.toLowerCase().contains(query.toLowerCase()) ||
                  s.artist.toLowerCase().contains(query.toLowerCase()),
            )
            .toList();

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    if (list.isEmpty) {
      return Center(
        child: Text(query.isEmpty ? '暂无热门歌曲' : '没有匹配「$query」的歌曲'),
      );
    }
    return ListView.builder(
      padding: EdgeInsets.only(
        bottom: 24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) => _ArtistSongRow(
        song: list[i],
        index: i,
        onTap: () => onPlaySongs(list, i),
      ),
    );
  }
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
        loader: (cursor) => widget.loader(widget.artistId, cursor).then(
              (p) => PagedPage(p.songs, hasMore: p.hasMore),
            ),
        itemBuilder: (context, song, index, items) => _ArtistSongRow(
          song: song,
          index: index,
          onTap: () => widget.onPlaySongs(items, index),
        ),
      );
    }
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_searchError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: _runQuery, child: const Text('重试')),
          ],
        ),
      );
    }
    final results = _searchResults ?? const <rust.SongDto>[];
    if (results.isEmpty) {
      return Center(child: Text('没有匹配「$_ranQuery」的歌曲'));
    }
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
  const _AlbumsTab({required this.albums, required this.onOpenAlbum});

  final List<rust.AlbumBrief> albums;
  final void Function(BigInt albumId, String albumName, String? coverUrl)?
  onOpenAlbum;

  @override
  Widget build(BuildContext context) {
    if (albums.isEmpty) {
      return const Center(child: Text('暂无专辑'));
    }
    final theme = Theme.of(context);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        12,
        12,
        12,
        24 + MediaQuery.viewPaddingOf(context).bottom,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.72,
      ),
      itemCount: albums.length,
      itemBuilder: (context, i) {
        final album = albums[i];
        final year = album.publishTime > BigInt.zero
            ? DateTime.fromMillisecondsSinceEpoch(
                album.publishTime.toInt(),
              ).year
            : null;
        return InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onOpenAlbum == null
              ? null
              : () => onOpenAlbum!(album.id, album.name, album.coverUrl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: CoverArt(url: album.coverUrl, radius: 6)),
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
      return const Center(child: Text('暂无 MV'));
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
        title: Text(
          mv.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
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

/// 热门歌曲行: 序号 + 歌名/歌手 + 时长 + SongOverflowButton。无版权灰显。
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                  Text(
                    song.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// 简介: 默认 3 行 + 展开/收起(与 detail_page 的 _ExpandableText 同思路)
class _ExpandableText extends StatefulWidget {
  const _ExpandableText({required this.text});

  final String text;

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Text(
            widget.text.trim(),
            maxLines: _expanded ? null : 3,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                _expanded ? '收起' : '展开',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
