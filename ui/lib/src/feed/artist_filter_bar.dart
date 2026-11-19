part of 'feed_view_body.dart';

// ───────────────────────────────────────────────────────────────────────────
// 分类横条的几何口径(渲染与"放几个"共用同一个值, 禁止两处各写 64)
// ───────────────────────────────────────────────────────────────────────────

/// 一个作者 chip 的宽度(头像 40 + 边框 4 + 文字列的实际占位)。
const double kAuthorChipWidth = 64;

/// "进入全部"这类文字更长的入口 chip 宽度。
const double kAuthorChipWideWidth = 84;

/// chip 之间的水平间距(由每个 chip 自己带的 right padding 实现)。
const double kAuthorChipGap = 10;

/// 横条至少展示多少个作者 chip —— **手机预算的兜底下限**。
///
/// 之前是写死 8 且与屏宽无关: 1280 的桌面窗口与 360 的手机放同样多个,
/// 宽屏右侧留一大片空白(用户 2026-11-18: "数量可以更多, 与动态主视图等宽")。
/// 但也不能反过来按"刚好铺满"算: 360dp 上只铺得下 2 个作者, 视野比改之前更窄。
/// 所以取「铺得下多少就放多少, 但不低于 8」—— 成品是**只增不减**。
const int kAuthorChipMinVisible = 8;

/// 横条按**实际可用宽**能放下多少个作者 chip(纯函数, 便于单测)。
///
/// [availableWidth] 必须是 LayoutBuilder 给的真实可用宽(不是 MediaQuery 窗口宽:
/// 桌面有内容限宽盒、横条还可能嵌在别的容器里)。
/// [fixedLeading]/[fixedTrailing] 是两条**固定入口**("全部" / "进入全部"),
/// 它们也占位, 漏算就会让宽屏多挤掉一个作者。
/// 结果永不超过 [total], 永不低于 [minVisible](至少 1)。
int visibleAuthorCountFor({
  required double availableWidth,
  required double chipWidth,
  required double gap,
  int fixedLeading = 1,
  int fixedTrailing = 1,
  required int total,
  int minVisible = kAuthorChipMinVisible,
}) {
  if (total <= 0) return 0;
  // 无限宽(无约束容器 / 测试里的 unbounded): 全部放出
  if (!availableWidth.isFinite) return total;
  final slot = chipWidth + gap;
  var fit = slot <= 0
      ? 0
      : (availableWidth / slot).floor() - (fixedLeading + fixedTrailing);
  if (fit < minVisible) fit = minVisible;
  if (fit < 1) fit = 1;
  return fit > total ? total : fit;
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

  /// 已按互动频率排序的**全部**本页发布者(截断交给 [visibleAuthorCountFor]:
  /// 放几个由实际可用宽决定, 不再由调用方写死)
  final List<_Author> authors;

  /// 本页发布者总数(> authors.length 时"进入全部"才有意义)
  final int totalAuthors;
  final BigInt? selected;

  /// 选中回调: null = 「全部」; 否则带上作者快照(名字/头像), 供 FeedView
  /// 把选中艺人钉在横条上并切换到 ta 自己的动态流。
  final void Function(_Author? author) onSelected;
  final Future<void> Function() onOpenAll;

  @override
  Widget build(BuildContext context) {
    if (authors.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      // 定高横滑条: 头像/内边距固定, 只有 11sp 标签随字号涨(写死 84 时 1.625 下竖溢 4dp)
      height: avatarStripHeightFor(context),
      // 用 LayoutBuilder 的**真实可用宽**算放几个(MediaQuery 窗口宽会把内容限宽盒、
      // 嵌入容器的内缩都算漏)。
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 末尾"进入全部"比普通 chip 宽 20, 先扣掉, 让"刚好铺满"的算式落在实宽上
          final usable =
              constraints.maxWidth -
              2 * kPagePadding -
              (kAuthorChipWideWidth - kAuthorChipWidth);
          final count = visibleAuthorCountFor(
            availableWidth: usable,
            chipWidth: kAuthorChipWidth,
            gap: kAuthorChipGap,
            total: authors.length,
          );
          return ListView(
            scrollDirection: Axis.horizontal,
            // 水平内边距与动态列表同口径(kPagePadding): 横条与主视图左右边缘共线
            padding: const EdgeInsets.fromLTRB(
              kPagePadding,
              8,
              kPagePadding,
              4,
            ),
            children: [
              _AuthorChip(
                label: '全部',
                avatarUrl: null,
                icon: Icons.all_inclusive,
                selected: selected == null,
                onTap: () => onSelected(null),
                scheme: scheme,
              ),
              for (final a in authors.take(count))
                _AuthorChip(
                  label: a.name,
                  avatarUrl: a.avatarUrl,
                  selected: selected == a.userId,
                  onTap: () => onSelected(a),
                  scheme: scheme,
                ),
              // 末尾固定一个"进入全部": 浏览所有艺人(本页 + 已关注)
              _AuthorChip(
                label: totalAuthors > count ? '进入全部($totalAuthors)' : '进入全部',
                avatarUrl: null,
                icon: Icons.grid_view,
                selected: false,
                onTap: onOpenAll,
                scheme: scheme,
                wide: true,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 横条上的一个 chip: 整块(含圆形头像)只做**页内聚焦**。
///
/// 用户口径(2026-11-18): 横条点头像**不再**进用户空间详情, 与点 chip 其它位置
/// 完全一致 —— 同一块区域给出两种结果最容易误触; 想进这个人的主页请点下方
/// 动态卡片里的头像(那里是唯一的主页入口)。
class _AuthorChip extends StatelessWidget {
  const _AuthorChip({
    required this.label,
    required this.avatarUrl,
    required this.selected,
    required this.onTap,
    required this.scheme,
    this.icon,
    this.wide = false,
  });

  final String label;
  final String? avatarUrl;
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
      padding: const EdgeInsets.only(right: kAuthorChipGap),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          width: wide ? kAuthorChipWideWidth : kAuthorChipWidth,
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
                    // 头像只是装饰, **不**包 UserAvatarTap(见类注释):
                    // 整个 chip 交给外层 InkWell 做页内聚焦。
                    : CircleCover(url: avatarUrl, size: 40),
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
                  // 回传作者快照(userId == 0 = 全部动态), 见 [_ArtistFilterBar.onSelected]
                  onTap: () =>
                      Navigator.of(context)
                          .pop(_Author(userId: BigInt.zero, name: '全部动态')),
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
                    // 整行(含头像与名字) = 筛选(把 userId 弹回 FeedView)。
                    // 2026-11-14 用户反馈 12: 这一栏的用途是"看这个人的动态",
                    // 以前头像是另一条路(进主页)、名字又是筛动态, 同一行两种结果;
                    // 现在统一成筛动态, 主页入口只留在下方的动态卡片里。
                    leading: CircleCover(url: a.avatarUrl, size: 40),
                    title: Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(a.subtitle),
                    trailing: widget.selected == a.userId
                        ? Icon(Icons.check, color: scheme.primary)
                        : null,
                    onTap: () => Navigator.of(context).pop(a),
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
                      onTap: () => Navigator.of(context).pop(
                        _Author(
                          userId: a.id,
                          name: a.name,
                          avatarUrl: a.avatarUrl,
                        ),
                      ),
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
