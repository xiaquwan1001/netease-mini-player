import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'cover_art.dart';
import 'layout.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;
import 'state_views.dart';

/// 歌单广场: 按分类浏览歌单(热门) / 精品歌单.
///
/// 数据来源: playlist_categories(分类) + playlists_by_category(分类歌单, 可分页)
/// + high_quality_playlists(精品歌单)。点卡片走歌单详情页。
///
/// 分类**天然带分组**, 不需要在 Dart 侧维护一张会过期的固定分组表:
/// 官方接口 `/api/playlist/catlist` 自己给出两级结构 ——
/// `categories:{0:"语种",1:"风格",2:"场景",3:"情感",4:"主题"}` 是一级分组,
/// `sub:[{category:0,name:"华语"},...]` 用 `category` 指回分组下标。
/// Rust 侧 `parse_playlist_categories`(core/crates/ncm-service/src/netease/
/// playlist.rs)已按 categories 的 key 排好序、把 sub 归到各自分组,
/// FFI 出来的 [rust.PlaylistCategory.group] / `.subs` 就是这里的分组与子分类。
/// 所以一级分组名、子分类名、分组个数全部以后台为准, 后台调整时 UI 自动跟随。
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

/// 歌单广场的两种浏览模式(互斥)。
enum _SquareMode {
  /// 热门: 按官方一级分组 + 子分类浏览热门歌单。
  hot,

  /// 精品: 官方 highquality/list, 一次性 50 条, 不按分类筛选。
  premium,
}

class _PlaylistSquareViewState extends State<PlaylistSquareView> {
  static const _pageSize = 30;

  /// '' = 全部分类(热门模式下的默认)
  String _cat = '';

  /// 广场模式(两者互斥): 热门 = 按官方分类浏览; 精品 = 官方精选, 不分分类。
  _SquareMode _mode = _SquareMode.hot;

  /// 分类区是否展开。默认展开(不然用户看不到有哪些分类), 选中某个具体分类后
  /// 自动收起, 把纵向空间还给歌单网格; 当前分类由筛选条上的摘要 chip 常驻显示。
  bool _categoriesExpanded = true;

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

  bool get _highQuality => _mode == _SquareMode.premium;

  /// 空态文案: 精品与分类浏览语义不同, 不要共用一句。
  String get _emptyText => _highQuality ? '暂时没有精品歌单' : '这个分类下暂时没有歌单';

  @override
  void initState() {
    super.initState();
    _loadCategoryList();
  }

  Future<void> _loadCategoryList() async {
    try {
      final list = await retryNetwork(_loadCategories);
      if (!mounted) return;
      // 成功后要顺手清掉上次的错误(重试路径靠它).
      setState(() {
        _categories = list;
        _categoriesError = null;
      });
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

  /// 选分类: 选中具体分类后自动收起分类区(只留摘要 chip),
  /// 选「全部分类」时重新展开 —— 分类多的时候不会一直霸占一屏。
  void _selectCategory(String cat) {
    if (cat == _cat) return;
    setState(() {
      _cat = cat;
      _categoriesExpanded = cat.isEmpty;
    });
  }

  /// 切换模式。精品模式不分分类, 进入时清空已选分类(与热门模式互斥)。
  void _setMode(_SquareMode mode) {
    if (mode == _mode) return;
    setState(() {
      _mode = mode;
      if (mode == _SquareMode.premium) _cat = '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PagedListView<rust.Playlist>(
      // 换分类/换模式都换 key: 新 key ⇒ PagedListView 重建 ⇒ 滚动位置回到顶部。
      key: ValueKey('${_mode.name}|$_cat'),
      loader: _pageLoader,
      gridDelegateBuilder: (context, availableWidth) => coverGridDelegate(
        availableWidth,
        columns: AppSettings.instance.gridColumns,
        crossAxisSpacing: 10,
        textScaler: MediaQuery.textScalerOf(context),
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      // 空态也要保留筛选条: PagedListView 的默认空态会整块替换 body,
      // 那时模式/分类切换条一起消失, 用户被锁在当前模式里回不去。
      emptyBuilder: (context, _) => SingleChildScrollView(
        child: Column(
          children: [
            _buildFilterBar(theme),
            const SizedBox(height: 24),
            EmptyView(title: _emptyText),
          ],
        ),
      ),
      header: _buildFilterBar(theme),
      itemBuilder: (context, pl, i, items) =>
          _PlaylistCard(playlist: pl, onTap: () => widget.onOpenPlaylist(pl)),
    );
  }

  Widget _buildFilterBar(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(kPagePadding, 8, 0, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模式互斥: 热门(按分类浏览) / 精品(官方精选), 用 segmented 控件表达
          // 「二选一」而不是并列的两个 chip。窄屏 + 大字号下仍然横向滚动兜底:
          // 换行会让筛选栏高度随文案跳动, 下方歌单网格跟着上下位移。
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Padding(
              padding: const EdgeInsets.only(right: kPagePadding),
              child: SegmentedButton<_SquareMode>(
                segments: const [
                  ButtonSegment(
                    value: _SquareMode.hot,
                    label: Text('热门'),
                    icon: Icon(Icons.local_fire_department, size: 18),
                  ),
                  ButtonSegment(
                    value: _SquareMode.premium,
                    label: Text('精品'),
                    icon: Icon(Icons.workspace_premium, size: 18),
                  ),
                ],
                selected: {_mode},
                showSelectedIcon: false,
                onSelectionChanged: (selection) => _setMode(selection.first),
              ),
            ),
          ),
          if (_categoriesError != null) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: kPagePadding),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      '分类加载失败',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    // 失败也能重试: 否则分类区永远是这一行错误文案
                    onPressed: _loadCategoryList,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          ] else if (_mode == _SquareMode.hot) ...[
            const SizedBox(height: 8),
            _buildCategoryHeader(theme),
            if (_categoriesExpanded) ..._buildCategoryGroups(theme),
          ] else ...[
            // 精品模式: 与分类互斥, 这里不放 chips, 只留一句说明
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(right: kPagePadding),
              child: Text(
                '官方精选 · 不分分类',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 分类区的摘要行: 左边常驻显示**当前分类**(收起时也能一眼看到),
  /// 右边是分类区的展开/收起开关。
  Widget _buildCategoryHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(right: kPagePadding),
      child: Row(
        children: [
          Flexible(
            child: _CatChip(
              label: _cat.isEmpty ? '全部分类' : '当前：$_cat',
              selected: true,
              // 点摘要 chip = 回到全部分类(顺带把分类区展开)
              onTap: _cat.isEmpty ? null : () => _selectCategory(''),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: _categories.isEmpty
                ? null
                : () => setState(
                    () => _categoriesExpanded = !_categoriesExpanded,
                  ),
            icon: Icon(
              _categoriesExpanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
            label: Text(_categoriesExpanded ? '收起分类' : '选择分类'),
            // 窄屏(300dp)+ 1.625 字号下摘要 chip 与这个按钮要挤进同一行,
            // 压掉 TextButton 默认的 16/24 横向留白(纵向触控高度仍走 Material 默认)。
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ],
      ),
    );
  }

  /// 分组 chips: 每组一行(组名 + 横向可滚的子分类)。
  ///
  /// 分组名与子分类名都来自接口(见文件头注释), 这里不维护任何固定分组表。
  List<Widget> _buildCategoryGroups(ThemeData theme) {
    final scheme = theme.colorScheme;
    return [
      for (final group in _categories) ...[
        const SizedBox(height: 6),
        Row(
          children: [
            // 组名给个上限: 官方现为 2 字(语种/风格/场景/情感/主题),
            // 万一后台换成长名也只省略自己这一列, 不挤扁 chips 行。
            // 组名列定宽(内容宽度, 不是间距): 各组 chips 的起始 x 才对齐;
            // 1.625 字号下 2 字约 36dp, 56 有余量, 更长的组名自己省略。
            SizedBox(
              width: 56,
              child: Text(
                group.group,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.outline,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final sub in group.subs)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _CatChip(
                          label: sub,
                          selected: _cat == sub,
                          onTap: () => _selectCategory(sub),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    ];
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

  /// null = 不可点(如已经是「全部分类」时的摘要 chip)。
  final VoidCallback? onTap;

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
          // 选中态除了底色再加一圈主色描边: 分类很多时底色差异不够醒目。
          border: selected ? Border.all(color: scheme.primary) : null,
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
