part of 'feed_view_body.dart';

/// 横向艺人分类: "全部" + 互动频率最高的若干发布者 + 末尾"进入全部"入口
class _ArtistFilterBar extends StatelessWidget {
  const _ArtistFilterBar({
    required this.authors,
    required this.totalAuthors,
    required this.selected,
    required this.onSelected,
    required this.onOpenAll,
  });

  /// 已按互动频率排序, 且已截断到"高频率的几位"
  final List<_Author> authors;

  /// 本页发布者总数(> authors.length 时"进入全部"才有意义)
  final int totalAuthors;
  final BigInt? selected;
  final void Function(BigInt? userId) onSelected;
  final Future<void> Function() onOpenAll;

  @override
  Widget build(BuildContext context) {
    if (authors.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      // 定高横滑条: 头像/内边距固定, 只有 11sp 标签随字号涨(写死 84 时 1.625 下竖溢 4dp)
      height: avatarStripHeightFor(context),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        children: [
          _AuthorChip(
            label: '全部',
            avatarUrl: null,
            icon: Icons.all_inclusive,
            selected: selected == null,
            onTap: () => onSelected(null),
            scheme: scheme,
          ),
          for (final a in authors)
            _AuthorChip(
              label: a.name,
              avatarUrl: a.avatarUrl,
              // 点头像进主页, 点整块仍是筛选(两者靠命中区区分, 见 _AuthorChip)。
              // 这里只有 feed 的 **user id**: 是艺人还是普通用户交给 UserNav 解析
              // (以前直接当 artistId 传, 会拿用户 id 去请求艺人详情)。
              userId: a.userId,
              selected: selected == a.userId,
              onTap: () => onSelected(a.userId),
              scheme: scheme,
            ),
          // 末尾固定一个"进入全部": 浏览所有艺人(本页 + 已关注)
          _AuthorChip(
            label: totalAuthors > authors.length
                ? '进入全部($totalAuthors)'
                : '进入全部',
            avatarUrl: null,
            icon: Icons.grid_view,
            selected: false,
            onTap: onOpenAll,
            scheme: scheme,
            wide: true,
          ),
        ],
      ),
    );
  }
}

class _AuthorChip extends StatelessWidget {
  const _AuthorChip({
    required this.label,
    required this.avatarUrl,
    required this.selected,
    required this.onTap,
    required this.scheme,
    this.icon,
    this.userId,
    this.wide = false,
  });

  final String label;
  final String? avatarUrl;

  /// 有值 = 头像可点进这个人的主页(艺人页/用户页由 UserNav 解析);
  /// 为空(「全部」「进入全部」这类纯筛选入口)不拦截点击。
  final BigInt? userId;
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
      padding: const EdgeInsets.only(right: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: SizedBox(
          width: wide ? 84 : 64,
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
                    // 只把 40dp 的头像包进 UserAvatarTap: 整块的 InkWell 仍是筛选,
                    // 命中区小才不会在点 chip 时误进主页。
                    : UserAvatarTap(
                        userId: userId ?? BigInt.zero,
                        nickname: label,
                        child: CircleCover(url: avatarUrl, size: 40),
                      ),
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
                  onTap: () => Navigator.of(context).pop(BigInt.zero),
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
                    onTap: () => Navigator.of(context).pop(a.userId),
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
                      onTap: () => Navigator.of(context).pop(a.id),
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
