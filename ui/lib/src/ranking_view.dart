import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'async_view.dart';
import 'cover_art.dart';
import 'layout.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'rust/api.dart' as rust;
import 'state_views.dart';

/// 听歌排行(需登录): 总量排行 + 当周排行.
///
/// 数据来自网易云"听歌排行"接口(type=0 全部时间 / type=1 最近一周),
/// 顺序即名次; [compact] 模式只展示前几条, 供"我的"页内嵌,
/// "查看全部"用 [showPlayRanking] 打开整页。
typedef RankingLoader = Future<List<rust.PlayRankEntryDto>> Function(
  String period,
);

/// 统计区间: 传 "all" / "week" 给 Rust 侧(见 ncm_provider::RankingPeriod)
const rankingPeriods = <(String, String)>[('all', '总排行'), ('week', '当周')];

Future<void> showPlayRanking(
  BuildContext context, {
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  RankingLoader? load,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('听歌排行')),
        body: PlayRankingView(onPlaySongs: onPlaySongs, load: load),
      ),
    ),
  );
}

class PlayRankingView extends StatefulWidget {
  const PlayRankingView({
    super.key,
    required this.onPlaySongs,
    this.load,
    this.compact = false,
    this.onOpenAll,
  });

  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final RankingLoader? load;

  /// 只展示前 5 条 + 一个"查看全部"入口("我的"页内嵌用)
  final bool compact;

  /// compact 模式下点"查看全部"
  final VoidCallback? onOpenAll;

  @override
  State<PlayRankingView> createState() => _PlayRankingViewState();
}

class _PlayRankingViewState extends State<PlayRankingView>
    with AutomaticKeepAliveClientMixin<PlayRankingView> {
  /// "all" = 全部时间(总量) / "week" = 最近一周
  String _period = 'all';

  RankingLoader get _loader =>
      widget.load ?? (period) => rust.playRanking(period: period);

  /// compact 内嵌模式的取数(重试由 AsyncView 内部套 retryNetwork);
  /// 整页模式由 PagedListView 负责加载。
  Future<List<rust.PlayRankEntryDto>> _load() => _loader(_period);

  void _switchPeriod(String period) {
    if (period == _period) return;
    setState(() {
      _period = period;
      // compact 模式靠 AsyncView 的 ValueKey(_period) 换代重挂载重新取数;
      // 整页模式由 PagedListView 的 key 重挂载触发
    });
  }

  /// 整页模式: 非分页单次加载, 三态(加载/错误/空)交给 PagedListView
  PagedLoader<rust.PlayRankEntryDto> get _pagedLoader {
    final period = _period;
    final raw = _loader;
    return (_) async {
      final entries = await retryNetwork(() => raw(period));
      return PagedPage(entries, hasMore: false);
    };
  }

  Widget _buildControls() {
    return Padding(
      // compact 内嵌在「我的」页时, 页面已有 kPagePadding, 这里不再叠一层
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 0 : kPagePadding,
      ),
      // 300dp + 1.625 字号下「三个分段 + 查看全部」会横向溢出 9.5px(实测)。
      // 分段控件改成 Flexible + FittedBox(scaleDown): 放不下时整组等比缩小,
      // 「查看全部」保持可点, 标题区不被挤没; 用 spaceBetween 顶到两端。
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: [
                  for (final (value, label) in rankingPeriods)
                    ButtonSegment<String>(value: value, label: Text(label)),
                ],
                selected: {_period},
                onSelectionChanged: (s) => _switchPeriod(s.first),
              ),
            ),
          ),
          if (widget.compact && widget.onOpenAll != null)
            TextButton(onPressed: widget.onOpenAll, child: const Text('查看全部')),
        ],
      ),
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!widget.compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildControls(),
          Expanded(
            child: PagedListView<rust.PlayRankEntryDto>(
              key: ValueKey(_period),
              loader: _pagedLoader,
              refreshable: false,
              emptyBuilder: (context, _) => EmptyView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                title: _period == 'week' ? '这周还没有听歌记录' : '还没有听歌记录(登录后听几首歌就有了)',
              ),
              itemBuilder: (context, e, i, items) {
                final playable = [
                  for (final e in items)
                    if (e.song.playable) e.song,
                ];
                return _RankRow(
                  rank: i + 1,
                  entry: e,
                  onTap: e.song.playable
                      ? () {
                          final index = playable.indexWhere(
                            (s) => s.id == e.song.id,
                          );
                          widget.onPlaySongs(playable, index < 0 ? 0 : index);
                        }
                      : null,
                );
              },
            ),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildControls(),
        AsyncView<List<rust.PlayRankEntryDto>>(
          // 收敛: 四态(加载/错误/空/数据)统一到 async_view.dart, 原来这里手写 FutureBuilder。
          // 换区间(总排行/当周)靠 key 换代重挂载 = 重新取数。
          key: ValueKey(_period),
          load: _load,
          keepAlive: true,
          emptyText: _period == 'week' ? '这周还没有听歌记录' : '还没有听歌记录(登录后听几首歌就有了)',
          // 空态沿用原来的 EmptyView 视觉, 文案一字未改。
          emptyBuilder: (context) => EmptyView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            title: _period == 'week' ? '这周还没有听歌记录' : '还没有听歌记录(登录后听几首歌就有了)',
          ),
          builder: (context, entries, reload) {
            final shown = entries.take(5).toList();
            final playable = [
              for (final e in entries)
                if (e.song.playable) e.song,
            ];
            return Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < shown.length; i++)
                    _RankRow(
                      rank: i + 1,
                      entry: shown[i],
                      padding: kCardRowPadding,
                      onTap: shown[i].song.playable
                          ? () {
                              final index = playable.indexWhere(
                                (s) => s.id == shown[i].song.id,
                              );
                              widget.onPlaySongs(
                                playable,
                                index < 0 ? 0 : index,
                              );
                            }
                          : null,
                    ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.rank,
    required this.entry,
    this.onTap,
    this.padding = kSongRowPadding,
  });

  final int rank;
  final rust.PlayRankEntryDto entry;

  /// 行留白: 整页排行用 kSongRowPadding(8/4);
  /// 「我的」页里嵌在卡片里时传 kCardRowPadding, 与同页入口行同一栅格。
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 前三名给主色, 其余用 outline, 一眼看出名次梯度
    final rankColor = rank <= 3 ? scheme.primary : scheme.outline;
    return ListTile(
      dense: true,
      visualDensity: VisualDensity.compact,
      // 用户反馈听歌排行左右有空隙: 默认 16+16 收到歌曲行统一留白
      contentPadding: padding,
      leading: SizedBox(
        // 名次(22) + 间距(4) + 封面(40), 给足宽度否则 ListTile 的 leading 会溢出
        // token-ok: 68 = 列宽 22 + 间距 4 + 封面 40, 是组合尺寸不是布局 token
        width: 68,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              // token-ok: 名次列宽按 "两位数" 内容宽度定
              width: 22,
              child: Text(
                '$rank',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: rankColor,
                  fontWeight: rank <= 3 ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 4),
            CoverArt(url: entry.song.coverUrl, size: 40, radius: 4),
          ],
        ),
      ),
      title: AdaptiveText(entry.song.name),
      subtitle: Text(
        entry.song.artist,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Text(
        '${entry.playCount} 次',
        style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline),
      ),
      onTap: onTap,
    );
  }
}
