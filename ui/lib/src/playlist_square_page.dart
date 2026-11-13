import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'cover_art.dart';
import 'layout.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;

/// 歌单广场: 按分类浏览歌单(热门) / 精品歌单.
///
/// 数据来源: playlist_categories(分类) + playlists_by_category(分类歌单, 可分页)
/// + high_quality_playlists(精品歌单)。点卡片走歌单详情页。
typedef CategoryLoader = Future<List<rust.PlaylistCategory>> Function();
typedef CategoryPageLoader = Future<List<rust.Playlist>> Function(
  String cat,
  int limit,
  int offset,
);
typedef HighQualityLoader = Future<List<rust.Playlist>> Function(
  String cat,
  int limit,
);

Future<void> showPlaylistSquare(
  BuildContext context, {
  required void Function(rust.Playlist playlist) onOpenPlaylist,
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

  final void Function(rust.Playlist playlist) onOpenPlaylist;
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

  List<rust.PlaylistCategory> _categories = const [];
  String? _categoriesError;

  CategoryLoader get _loadCategories =>
      widget.loadCategories ?? rust.playlistCategories;
  CategoryPageLoader get _loadPage =>
      widget.loadPage ??
      (cat, limit, offset) =>
          rust.playlistsByCategory(cat: cat, limit: limit, offset: offset);
  HighQualityLoader get _loadHighQuality =>
      widget.loadHighQuality ??
      (cat, limit) => rust.highQualityPlaylists(cat: cat, limit: limit);

  @override
  void initState() {
    super.initState();
    _loadCategoryList();
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

  /// 精品歌单一次性拉 50 条, 不分页; 分类歌单按 offset 分页
  PagedLoader<rust.Playlist> get _pageLoader {
    final cat = _cat;
    final hq = _highQuality;
    if (hq) {
      final loadHq = _loadHighQuality;
      return (_) async {
        final page = await retryNetwork(() => loadHq(cat, 50));
        return PagedPage(page, hasMore: false);
      };
    }
    final loadPage = _loadPage;
    return (cursor) async {
      final page = await retryNetwork(() => loadPage(cat, _pageSize, cursor));
      return PagedPage(page, hasMore: page.length >= _pageSize);
    };
  }

  void _select(String cat, {bool? highQuality}) {
    final nextHq = highQuality ?? _highQuality;
    if (cat == _cat && nextHq == _highQuality) return;
    setState(() {
      _cat = cat;
      _highQuality = nextHq;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PagedListView<rust.Playlist>(
      key: ValueKey('$_highQuality|$_cat'),
      loader: _pageLoader,
      gridDelegate: coverGridDelegate(
        context,
        columns: AppSettings.instance.gridColumns,
        crossAxisSpacing: 10,
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      emptyText: '这个分类下暂时没有歌单',
      header: _buildFilterBar(theme),
      itemBuilder: (context, pl, i, items) =>
          _PlaylistCard(playlist: pl, onTap: () => widget.onOpenPlaylist(pl)),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 窄屏 + 大字号下「热门 + 精品 + 分类加载失败」会超出 300dp:
          // 这里必须横向滚动而不是 Wrap —— 用 Wrap 换行会让筛选栏高度随错误文案
          // 跳动, 上方的歌单网格跟着上下位移(用户滚动位置被顶掉)。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
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
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
              ],
            ),
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
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.outline,
                      ),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
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

  final rust.Playlist playlist;
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
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
