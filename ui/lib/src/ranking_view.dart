import 'package:flutter/material.dart';

import 'cover_art.dart';
import 'net_retry.dart';
import 'rust/api.dart' as rust;

/// 听歌排行(需登录): 总量排行 + 当周排行.
///
/// 数据来自网易云"听歌排行"接口(type=0 全部时间 / type=1 最近一周),
/// 顺序即名次; [compact] 模式只展示前几条, 供"我的"页内嵌,
/// "查看全部"用 [showPlayRanking] 打开整页。
typedef RankingLoader = Future<List<rust.PlayRankEntryDto>> Function(String period);

/// 统计区间: 传 "all" / "week" 给 Rust 侧(见 ncm_provider::RankingPeriod)
const rankingPeriods = <(String, String)>[
  ('all', '总排行'),
  ('week', '当周'),
];

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

class _PlayRankingViewState extends State<PlayRankingView> {
  /// "all" = 全部时间(总量) / "week" = 最近一周
  String _period = 'all';
  late Future<List<rust.PlayRankEntryDto>> _future;

  RankingLoader get _loader =>
      widget.load ?? (period) => rust.playRanking(period: period);

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<rust.PlayRankEntryDto>> _load() =>
      retryNetwork(() => _loader(_period));

  void _switchPeriod(String period) {
    if (period == _period) return;
    setState(() {
      _period = period;
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              SegmentedButton<String>(
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
              const Spacer(),
              if (widget.compact && widget.onOpenAll != null)
                TextButton(
                  onPressed: widget.onOpenAll,
                  child: const Text('查看全部'),
                ),
            ],
          ),
        ),
        FutureBuilder<List<rust.PlayRankEntryDto>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        friendlyError(snap.error!),
                        style: TextStyle(
                          color: theme.colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _future = _load()),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              );
            }
            final entries = snap.data ?? const <rust.PlayRankEntryDto>[];
            if (entries.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Text(
                  _period == 'week'
                      ? '这周还没有听歌记录'
                      : '还没有听歌记录(登录后听几首歌就有了)',
                  style: theme.textTheme.bodySmall,
                ),
              );
            }
            final shown =
                widget.compact ? entries.take(5).toList() : entries;
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
                      onTap: shown[i].song.playable
                          ? () {
                              final index = playable.indexWhere(
                                (s) => s.id == shown[i].song.id,
                              );
                              widget.onPlaySongs(playable, index < 0 ? 0 : index);
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
  const _RankRow({required this.rank, required this.entry, this.onTap});

  final int rank;
  final rust.PlayRankEntryDto entry;
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
      leading: SizedBox(
        // 名次(22) + 间距(4) + 封面(40), 给足宽度否则 ListTile 的 leading 会溢出
        width: 68,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
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
      title: Text(
        entry.song.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
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
