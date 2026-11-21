import 'package:flutter/material.dart';

import 'adaptive_text.dart';
import 'async_view.dart';
import 'cover_art.dart';
import 'layout.dart';
import 'now_playing.dart';
import 'net_retry.dart';
import 'paged_list_view.dart';
import 'playback_bridge.dart';
import 'rust/api_all.dart' as rust;
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

Future<void> showPlayRanking(BuildContext context, {RankingLoader? load}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('听歌排行')),
        body: PlayRankingView(load: load),
      ),
    ),
  );
}

class PlayRankingView extends StatefulWidget {
  const PlayRankingView({
    super.key,
    this.load,
    this.compact = false,
    this.onOpenAll,
    this.periods,
    this.emptyText,
  });

  final RankingLoader? load;

  /// 只展示前 5 条 + 一个"查看全部"入口("我的"页内嵌用)
  final bool compact;

  /// compact 模式下点"查看全部"
  final VoidCallback? onOpenAll;

  /// 周期分段的分组标签(默认 [rankingPeriods] 的总排行/当周)。
  /// 他人主页用「所有时间 / 最近一周」——那是官方页面上的原话,
  /// "总排行/当周"是「我的」页的历史措辞, 两处不要互相改名。
  final List<(String, String)>? periods;

  /// 空态文案覆盖。默认是"我自己没听歌"的口径("登录后听几首歌就有了"),
  /// 挂在他人主页时必须换掉: 这句在别人的页面上没有任何意义。
  final String? emptyText;

  @override
  State<PlayRankingView> createState() => _PlayRankingViewState();
}

class _PlayRankingViewState extends State<PlayRankingView>
    with AutomaticKeepAliveClientMixin<PlayRankingView> {
  /// "all" = 全部时间(总量) / "week" = 最近一周
  String _period = 'all';

  RankingLoader get _loader =>
      widget.load ?? (period) => rust.playRanking(period: period);

  /// 实际用于分段控件的标签组
  List<(String, String)> get _periods => widget.periods ?? rankingPeriods;

  /// 当前区间的空态文案
  String get _emptyText =>
      widget.emptyText ??
      (_period == 'week' ? '这周还没有听歌记录' : '还没有听歌记录(登录后听几首歌就有了)');

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
                  for (final (value, label) in _periods)
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
                title: _emptyText,
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
                          PlaybackBridge.instance.playSongs(
                            playable,
                            index < 0 ? 0 : index,
                          );
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
          emptyText: _emptyText,
          // 空态沿用原来的 EmptyView 视觉(默认文案一字未改)。
          emptyBuilder: (context) => EmptyView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            title: _emptyText,
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
                              PlaybackBridge.instance.playSongs(
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

/// 一行排行.
///
/// 口径(2026-11-19 核对官方接口后固化):
/// - **名次** = 列表下标 + 1。Rust 侧 [rust.PlayRankEntryDto] 的顺序就是接口
///   返回顺序, 也就是官方名次(不再按 score 客户端重排, 见
///   `ncm-service/song.rs` 的 `parse_play_ranking`)。
/// - **次数** = `playCount` 字段: 总榜是累计播放次数, 周榜是本周播放次数。
/// - `score` 是接口给的**归一化分值**(实测 = floor(playCount / 最大值 * 100),
///   最高 100), 不是名次也不是播放次数, 所以这里不显示。
class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.rank,
    required this.entry,
    this.onTap,
    this.padding = kPageRowPadding,
  });

  final int rank;
  final rust.PlayRankEntryDto entry;

  /// 行留白: 整页排行用 kPageRowPadding(12/4);
  /// 「我的」页里嵌在卡片里时传 kCardRowPadding, 与同页入口行同一栅格。
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 排行榜里正在播放的那首也要标出来(用户反馈: 列表里认不出正在放的歌)
    return NowPlayingHighlight(
      songId: entry.song.id,
      builder: (context, playing) => _buildRow(context, playing),
    );
  }

  Widget _buildRow(BuildContext context, bool playing) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 前三名给主色, 其余用 outline, 一眼看出名次梯度
    final rankColor = rank <= 3 ? scheme.primary : scheme.outline;
    return LayoutBuilder(
      builder: (context, box) => rowHeightBox(
        context,
        ListTile(
          selected: playing,
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
                  child: playing
                      ? Icon(Icons.volume_up, size: 16, color: scheme.primary)
                      : Text(
                          '$rank',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: rankColor,
                            fontWeight: rank <= 3
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                ),
                const SizedBox(width: 4),
                CoverArt(url: entry.song.coverUrl, size: 40, radius: 4),
              ],
            ),
          ),
          title: AdaptiveText(
            entry.song.name,
            style: playing
                ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w600)
                : null,
          ),
          subtitle: Text(
            entry.song.artist,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: capRowTrailing(
            box.maxWidth,
            Text(
              '${entry.playCount} 次',
              // 播放次数位数可变('1234567 次' ≈ 70dp, 1.625 字号下更宽)也算
              // 行尾: 不封顶会把歌名挤扁(列表行审计 B8)。
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.outline,
              ),
            ),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}
