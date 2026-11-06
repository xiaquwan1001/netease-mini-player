import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 歌单广场: 按分类浏览歌单(热门) / 精品歌单.
///
/// 数据来源: playlist_categories(分类) + playlists_by_category(分类歌单, 可分页)
/// + high_quality_playlists(精品歌单)。点卡片走歌单详情页。
typedef CategoryLoader = Future<List<rust.PlaylistCategoryDto>> Function();
typedef CategoryPageLoader = Future<List<rust.PlaylistDto>> Function(
    String cat, int limit, int offset);
typedef HighQualityLoader = Future<List<rust.PlaylistDto>> Function(
    String cat, int limit);

Future<void> showPlaylistSquare(
  BuildContext context, {
  required void Function(rust.PlaylistDto playlist) onOpenPlaylist,
  CategoryLoader? loadCategories,
  CategoryPageLoader? loadPage,
  HighQualityLoader? loadHighQuality,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('歌单广场')),
        body: PlaylistSquareView(
          onOpenPlaylist: onOpenPlaylist,
          loadCategories: loadCategories,
          loadPage: loadPage,
          loadHighQuality: loadHighQuality,
        ),
      ),
    ),
  );
}

class PlaylistSquareView extends StatefulWidget {
  const PlaylistSquareView({
    super.key,
    required this.onOpenPlaylist,
    this.loadCategories,
    this.loadPage,
    this.loadHighQuality,
  });

  final void Function(rust.PlaylistDto playlist) onOpenPlaylist;
  final CategoryLoader? loadCategories;
  final CategoryPageLoader? loadPage;
  final HighQualityLoader? loadHighQuality;

  @override
  State<PlaylistSquareView> createState() => _PlaylistSquareViewState();
}

class _PlaylistSquareViewState extends State<PlaylistSquareView> {
  static const _pageSize = 30;

  /// '' = 全部分类
  String _cat = '';
  bool _highQuality = false;

  List<rust.PlaylistCategoryDto> _categories = const [];
  String? _categoriesError;

  final List<rust.PlaylistDto> _items = [];
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;

  CategoryLoader get _loadCategories =>
      widget.loadCategories ?? rust.playlistCategories;
  CategoryPageLoader get _loadPage =>
      widget.loadPage ??
      (cat, limit, offset) => rust.playlistsByCategory(
            cat: cat,
            limit: limit,
            offset: offset,
          );
  HighQualityLoader get _loadHighQuality =>
      widget.loadHighQuality ??
      (cat, limit) => rust.highQualityPlaylists(cat: cat, limit: limit);

  @override
  void initState() {
    super.initState();
    _loadCategoryList();
    _reload();
  }

  Future<void> _loadCategoryList() async {
    try {
      final list = await retryNetwork(_loadCategories);
      if (!mounted) return;
      setState(() => _categories = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _categoriesError = friendlyError(e));
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _hasMore = true;
      _items.clear();
    });
    try {
      final page = _highQuality
          ? await retryNetwork(() => _loadHighQuality(_cat, 50))
          : await retryNetwork(() => _loadPage(_cat, _pageSize, 0));
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _hasMore = !_highQuality && page.length >= _pageSize;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _highQuality) return;
    setState(() => _loadingMore = true);
    try {
      final page = await retryNetwork(() => _loadPage(_cat, _pageSize, _items.length));
      if (!mounted) return;
      setState(() {
        _items.addAll(page);
        _hasMore = page.length >= _pageSize;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(friendlyError(e))));
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _select(String cat, {bool? highQuality}) {
    final nextHq = highQuality ?? _highQuality;
    if (cat == _cat && nextHq == _highQuality) return;
    setState(() {
      _cat = cat;
      _highQuality = nextHq;
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _reload,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildFilterBar(theme)),
          if (_loading)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.tonal(onPressed: _reload, child: const Text('重试')),
                  ],
                ),
              ),
            )
          else if (_items.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text('这个分类下暂时没有歌单', style: theme.textTheme.bodySmall),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 180,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.72,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _PlaylistCard(
                    playlist: _items[i],
                    onTap: () => widget.onOpenPlaylist(_items[i]),
                  ),
                  childCount: _items.length,
                ),
              ),
            ),
          SliverToBoxAdapter(child: _buildFooter(theme)),
        ],
      ),
    );
  }

  Widget _buildFooter(ThemeData theme) {
    if (_loading) return const SizedBox(height: 24);
    if (!_hasMore || _highQuality) {
      return const SizedBox(height: 24);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      child: Center(
        child: _loadingMore
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : OutlinedButton(
                onPressed: _loadMore,
                child: const Text('加载更多'),
              ),
      ),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _CatChip(
                label: '热门',
                selected: !_highQuality && _cat.isEmpty,
                onTap: () => _select('', highQuality: false),
              ),
              const SizedBox(width: 8),
              _CatChip(
                label: '精品',
                selected: _highQuality && _cat.isEmpty,
                onTap: () => _select('', highQuality: true),
              ),
              if (_categoriesError != null) ...[
                const SizedBox(width: 8),
                Text(
                  '分类加载失败',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: scheme.error),
                ),
              ],
            ],
          ),
          for (final group in _categories) ...[
            const SizedBox(height: 6),
            SizedBox(
              height: 34,
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(
                      group.group,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: scheme.outline),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [
                        for (final sub in group.subs)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _CatChip(
                              label: sub,
                              selected: _cat == sub,
                              onTap: () => _select(sub),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CatChip extends StatelessWidget {
  const _CatChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: selected ? scheme.onPrimaryContainer : null,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({required this.playlist, required this.onTap});

  final rust.PlaylistDto playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, box) => CoverArt(
                url: playlist.coverUrl,
                size: box.maxWidth,
                radius: 8,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            playlist.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          Text(
            '${playlist.trackCount} 首',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}
