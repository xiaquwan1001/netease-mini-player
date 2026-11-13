import 'package:flutter/material.dart';

import 'layout.dart';
import 'profile_banner.dart';

// ───────────────────────────────────────────────────────────────────────────
// 艺人主页 / 他人主页共用的**页面骨架**(需求 9)
//
// 两个页面此前是两份手写结构: 艺人页 = NestedScrollView + SliverAppBar(横幅) +
// 身份卡 + 信息区 + pinned 搜索条 + pinned TabBar; 用户页 = AppBar + ListView
// (横幅塞在卡片里, 没有 tab, 只有一列 ListTile 歌单)。
// 统一后两边只有**数据与分区内容**不同, 骨架/几何/统计行/tab 生成全部走这里:
//
//   SliverAppBar(pinned, expandedHeight = kProfileBannerHeight, 背景横幅)
//   ├─ ProfileIdentity(身份卡, 在横幅下沿; 这里身份卡是 sliver 子节点, 不上浮)
//   ├─ sections(统计行之外的分区: 简介/推荐单曲/专辑/相似歌手 …)
//   ├─ 可选 pinned 搜索条(页内过滤)
//   └─ pinned TabBar(由 ProfileTabSpec 列表生成)
//   body = TabBarView(每个 spec 自己构建内容)
// ───────────────────────────────────────────────────────────────────────────

/// pinned 页内搜索条的高度(与 artist_page 原实现一致)。
const double kProfileSearchBarExtent = 56;

/// 一条 tab 的声明式规格。
///
/// tab 集合由**数据可用性**生成(艺人: 全部歌曲 / 专辑(有专辑) / MV(有 MV);
/// 用户: 歌单 / 关注(有) / 粉丝(有)), 不再在 setState 里手写 index 判断。
class ProfileTabSpec {
  const ProfileTabSpec(this.label, {required this.builder, this.badge});

  /// TabBar 上的文案。
  final String label;

  /// tab 内容(懒构建: 只有可见页才会 build)。
  final WidgetBuilder builder;

  /// 可选计数徽标(如「关注」tab 上的「12」)。
  final Widget? badge;
}

/// tab 计数徽标(药丸)。
class ProfileTabBadge extends StatelessWidget {
  const ProfileTabBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 统一统计 chip: 关注 / 粉丝(可点) / 等级 / `N 专辑 · M 首歌曲`。
///
/// 放在 [ProfileIdentity.footer] 槽位里, 两页共用同一套尺寸与节奏;
/// 可点的 chip 额外带 chevron 且包一层 InkWell(300dp + 1.625 字号仍不溢出:
/// 文案单行 ellipsis, chip 自身在 [ProfileStatRow] 的 Wrap 里换行)。
class ProfileStatChip extends StatelessWidget {
  const ProfileStatChip({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
  });

  final String label;
  final IconData? icon;

  /// 非空 = 可点(关注/粉丝入口); 为空 = 纯展示(等级/作品数)。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tappable = onTap != null;
    final radius = BorderRadius.circular(12);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: radius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: scheme.onSurfaceVariant),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: tappable ? FontWeight.w600 : null,
              ),
            ),
          ),
          if (tappable) ...[
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 14, color: scheme.onSurfaceVariant),
          ],
        ],
      ),
    );
    if (!tappable) return chip;
    return InkWell(
      onTap: onTap,
      borderRadius: radius,
      child: Semantics(button: true, child: chip),
    );
  }
}

/// 统计行: 一组 [ProfileStatChip], 放不下自动换行(300dp + 大字号不溢出)。
class ProfileStatRow extends StatelessWidget {
  const ProfileStatRow({super.key, required this.chips});

  final List<Widget> chips;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 6, runSpacing: 4, children: chips);
  }
}

/// 艺人页的 `N 个专辑 · M 首歌曲` 统计 chip。
class ProfileWorksStatChip extends StatelessWidget {
  const ProfileWorksStatChip({
    super.key,
    required this.albumCount,
    required this.songCount,
  });

  final BigInt albumCount;
  final BigInt songCount;

  @override
  Widget build(BuildContext context) {
    return ProfileStatChip(
      icon: Icons.album_outlined,
      label: '$albumCount 个专辑 · $songCount 首歌曲',
    );
  }
}

/// 统一页面骨架(见文件头注释)。
class ProfileScaffold extends StatelessWidget {
  const ProfileScaffold({
    super.key,
    required this.banner,
    required this.identity,
    required this.tabs,
    required this.controller,
    this.sections = const <Widget>[],
    this.collapsedTitle,
    this.actions,
    this.searchBar,
    this.scrollController,
    this.tabBarKey,
  });

  /// SliverAppBar 的 flexibleSpace 背景(通常是 [ProfileBannerImage])。
  final Widget banner;

  /// 身份卡(通常是 [ProfileIdentity]), 落在横幅下沿、TabBar 之上。
  final Widget identity;

  /// tab 集合(按数据可用性生成)。
  final List<ProfileTabSpec> tabs;

  /// 外部持有的 TabController(页数变化时用 [syncProfileTabs] 换新)。
  final TabController controller;

  /// 身份卡与 TabBar 之间的滚动分区(简介/推荐单曲/专辑 …); 每项自带标题。
  final List<Widget> sections;

  /// 顶栏收起时显示的标题(展开时横幅里已有名字, 不重复显示)。
  final String? collapsedTitle;

  /// 顶栏右侧动作(如页内搜索开关)。
  final List<Widget>? actions;

  /// 可选 pinned 页内搜索条(高度按 [kProfileSearchBarExtent])。
  final Widget? searchBar;

  final ScrollController? scrollController;

  /// pinned TabBar 的 key(测试按它做几何断言)。
  final Key? tabBarKey;

  @override
  Widget build(BuildContext context) {
    final search = searchBar;
    return Scaffold(
      body: NestedScrollView(
        controller: scrollController,
        headerSliverBuilder: (context, innerBoxIsScrolled) => [
          SliverAppBar(
            pinned: true,
            expandedHeight: kProfileBannerHeight,
            title: collapsedTitle == null
                ? null
                : Text(
                    collapsedTitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
            actions: actions,
            flexibleSpace: FlexibleSpaceBar(background: banner),
          ),
          // 身份卡(头像/名字/别名/统计): 横幅之下, 不压图
          SliverToBoxAdapter(child: identity),
          if (sections.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                // 与全仓栅格一致: 左 12 / 右 12, 顶部 8
                padding: const EdgeInsets.fromLTRB(
                  kPagePadding,
                  8,
                  kPagePadding,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: sections,
                ),
              ),
            ),
          if (search != null)
            SliverPersistentHeader(
              pinned: true,
              delegate: ProfilePinnedHeaderDelegate(
                child: search,
                extent: kProfileSearchBarExtent,
              ),
            ),
          SliverPersistentHeader(
            pinned: true,
            delegate: ProfilePinnedHeaderDelegate(
              child: TabBar(
                key: tabBarKey,
                controller: controller,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final t in tabs) _tabWidget(t)],
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: controller,
          children: [for (final t in tabs) t.builder(context)],
        ),
      ),
    );
  }

  Widget _tabWidget(ProfileTabSpec spec) {
    final badge = spec.badge;
    if (badge == null) return Tab(text: spec.label);
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(spec.label, maxLines: 1)),
          const SizedBox(width: 4),
          badge,
        ],
      ),
    );
  }
}

/// pinned sliver 头的通用实现(TabBar / 搜索条共用同一底色与重建策略)。
class ProfilePinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  const ProfilePinnedHeaderDelegate({required this.child, this.extent});

  final Widget child;

  /// 显式高度; null 时按 child 推断(TabBar 用 preferredSize)。
  final double? extent;

  double get _height {
    final e = extent;
    if (e != null) return e;
    final c = child;
    if (c is TabBar) return c.preferredSize.height;
    return kToolbarHeight;
  }

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: child,
    );
  }

  @override
  bool shouldRebuild(ProfilePinnedHeaderDelegate oldDelegate) =>
      oldDelegate.child != child || oldDelegate.extent != extent;
}

/// 按新的 tab 数量重建 [TabController](两页共用的时序修复)。
///
/// 旧 controller 还被**当前帧**的 TabBar/TabBarView 引用, 立刻 dispose 会抛
/// "A TabController was used after being disposed"; 所以一律延到帧末释放
/// (此前 artist_page 里踩过的坑, 现在收敛到一处)。
TabController syncProfileTabs({
  required TickerProvider vsync,
  required TabController current,
  required int length,
  required VoidCallback onChanged,
  int? initialIndex,
}) {
  if (current.length == length) return current;
  var keep = initialIndex ?? current.index;
  if (keep >= length) keep = length - 1;
  if (keep < 0) keep = 0;
  final next = TabController(length: length, vsync: vsync, initialIndex: keep)
    ..addListener(onChanged);
  WidgetsBinding.instance.addPostFrameCallback((_) => current.dispose());
  return next;
}
