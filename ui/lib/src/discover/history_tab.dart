import 'package:flutter/material.dart';

import '../async_view.dart';
import '../cover_art.dart';
import '../daily_cache.dart';
import '../error_views.dart' show FullError;
import '../net_retry.dart' show friendlyError, retryNetwork;
import '../rust/api.dart' as rust;
import '../state_views.dart';
import '../song_tile.dart' show SongRow, SongRowLayout, SongRowSubtitle;
import 'discover_types.dart';

/// 历史日推的一行: 在线日期 / 本地缓存日期 / 两者都有(合并去重后只留一行).
class _HistoryEntry {
  const _HistoryEntry({
    required this.date,
    required this.remote,
    required this.local,
  });

  /// YYYY-MM-DD
  final String date;

  /// 服务端历史日推里有这一天(VIP 才能取到曲目)
  final bool remote;

  /// 这一天本地缓存的推荐歌单(可能为空)
  final List<rust.Playlist> local;

  bool get hasLocal => local.isNotEmpty;
}

/// 在线日期取失败、本地也没有缓存时的整屏错误: 文案已经过 [friendlyError],
/// 包成异常只是为了让 [AsyncView] 把它当"错误态"渲染(不让它再被重试一遍)。
class _HistoryDatesError implements Exception {
  const _HistoryDatesError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 「历史日推」页签: 在线日期 + 本地缓存按日期合并去重, 内部还有一层
/// "某一天的日推"二级页(返回键先回日期列表, 见 [PopScope]).
///
/// 两级各自是一块整页加载, 四态都收敛到 [AsyncView]:
/// - 日期列表([_HistoryDatesView]): 在线日期失败但本地有缓存时**不整屏报错**,
///   降级成列表顶部一行提示(见 [_HistoryDatesViewState._remoteError]);
/// - 某一天([_HistoryDayView]): 曲目加载, 空态仍保留"返回日期列表"头部。
class HistoryTab extends StatefulWidget {
  const HistoryTab({
    super.key,
    required this.loadDates,
    required this.loadSongs,
    required this.onPlay,
    this.loadLocalDays,
    this.onOpenPlaylist,
  });

  final DateListLoader loadDates;
  final HistorySongsLoader loadSongs;
  final void Function(List<rust.SongDto> songs, int index) onPlay;

  /// 本地缓存的天(设置里关掉缓存时由上层传 null)
  final LocalDaysLoader? loadLocalDays;

  /// 本地日期下点歌单(不传则该行不可点)
  final void Function(rust.Playlist playlist)? onOpenPlaylist;

  @override
  State<HistoryTab> createState() => HistoryTabState();
}

class HistoryTabState extends State<HistoryTab>
    with AutomaticKeepAliveClientMixin {
  /// 选中的日期(非空时展示那一天的曲目/本地歌单)
  _HistoryEntry? _selected;

  @override
  bool get wantKeepAlive => true;

  void _openDay(_HistoryEntry entry) => setState(() => _selected = entry);

  void _closeDay() => setState(() => _selected = null);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final selected = _selected;
    // 审查 P1-7.14: 「某一天的日推」是本页内部的二级层级,
    // 系统返回键 / AppBar 返回箭头都应先退回日期列表, 而不是直接关掉整页。
    return PopScope(
      canPop: selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _selected == null) return;
        _closeDay();
      },
      child: selected == null
          ? _HistoryDatesView(
              loadDates: widget.loadDates,
              loadLocalDays: widget.loadLocalDays,
              onOpen: _openDay,
            )
          : _HistoryDayView(
              // 换日期要重建四态, 不能复用上一天的 future
              key: ValueKey<String>(selected.date),
              entry: selected,
              loadSongs: widget.loadSongs,
              onPlay: widget.onPlay,
              onOpenPlaylist: widget.onOpenPlaylist,
              onClose: _closeDay,
            ),
    );
  }
}

/// 日期列表(一级): 在线最近 5 次 + 本地缓存按日期合并去重.
class _HistoryDatesView extends StatefulWidget {
  const _HistoryDatesView({
    required this.loadDates,
    required this.onOpen,
    this.loadLocalDays,
  });

  final DateListLoader loadDates;
  final LocalDaysLoader? loadLocalDays;
  final void Function(_HistoryEntry entry) onOpen;

  @override
  State<_HistoryDatesView> createState() => _HistoryDatesViewState();
}

class _HistoryDatesViewState extends State<_HistoryDatesView> {
  /// 在线侧失败、本地还有内容时的降级提示(不整屏报错, 见 [_load]).
  String? _remoteError;

  late Future<List<_HistoryEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// 重试/刷新日期列表. 用块体: 箭头体会把 Future 变成 setState 回调的返回值,
  /// Flutter 会因此断言失败(AsyncView._reload 同款注释)。
  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  /// 在线日期与本地缓存并行加载: 本地读盘失败只是"少几行", 不能拖垮整页.
  ///
  /// 走 [AsyncView.future] 形态(而不是 load): 这一块的"取数"要合并两个来源,
  /// 在线那条自己套 [retryNetwork], 由本方法决定是降级还是整屏报错。
  Future<List<_HistoryEntry>> _load() async {
    _remoteError = null;
    final localLoader = widget.loadLocalDays;
    final localFuture = localLoader == null
        ? Future<List<DailyCacheDay>>.value(const <DailyCacheDay>[])
        : localLoader().catchError((_) => const <DailyCacheDay>[]);
    List<String>? dates;
    String? remoteError;
    try {
      dates = await retryNetwork(widget.loadDates);
    } catch (e) {
      remoteError = friendlyError(e);
    }
    final local = await localFuture;
    if (dates == null) {
      if (local.isEmpty) {
        // 在线侧失败且本地也没有缓存时才整屏报错(带重试按钮)。
        throw _HistoryDatesError(remoteError ?? '');
      }
      _remoteError = remoteError;
    }
    return _merge(dates ?? const [], local);
  }

  @override
  Widget build(BuildContext context) {
    return AsyncView<List<_HistoryEntry>>(
      future: _future,
      onRetry: _reload,
      emptyText: '最近 5 次日推仅黑胶 VIP 可见',
      loadingBuilder: (_) => const LoadingView(),
      emptyBuilder: (_) => const EmptyView(
        icon: Icons.vpn_key_outlined,
        title: '最近 5 次日推仅黑胶 VIP 可见\n(开通后明天再来就会出现在这里)',
      ),
      errorBuilder: (_, error, retry) => FullError(
        message: error is _HistoryDatesError
            ? error.message
            : friendlyError(error),
        onRetry: retry,
      ),
      builder: (context, entries, reload) => _list(context, entries, reload),
    );
  }

  Widget _list(
    BuildContext context,
    List<_HistoryEntry> entries,
    VoidCallback reload,
  ) {
    final remoteError = _remoteError;
    final hasRemoteError = remoteError != null;
    // 非分页: 在线最近 5 次 + 本地缓存天, 条数有限
    return ListView.separated(
      itemCount: entries.length + (hasRemoteError ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (hasRemoteError && i == 0) {
          return ListTile(
            leading: const Icon(Icons.cloud_off_outlined),
            title: const Text('在线历史日推获取失败'),
            subtitle: Text(remoteError),
            trailing: TextButton(onPressed: reload, child: const Text('重试')),
          );
        }
        final entry = entries[hasRemoteError ? i - 1 : i];
        return ListTile(
          leading: Icon(
            entry.remote ? Icons.history : Icons.offline_pin_outlined,
          ),
          title: Row(
            children: [
              Text(entry.date),
              if (entry.hasLocal) ...[
                const SizedBox(width: 8),
                const _LocalBadge(),
              ],
            ],
          ),
          subtitle: Text(_subtitleOf(entry)),
          onTap: () => widget.onOpen(entry),
        );
      },
    );
  }
}

/// 某一天的日推(二级): 在线日期取曲目, 纯本地日期直接展示缓存的推荐歌单.
class _HistoryDayView extends StatelessWidget {
  const _HistoryDayView({
    super.key,
    required this.entry,
    required this.loadSongs,
    required this.onPlay,
    required this.onClose,
    this.onOpenPlaylist,
  });

  final _HistoryEntry entry;
  final HistorySongsLoader loadSongs;
  final void Function(List<rust.SongDto> songs, int index) onPlay;
  final void Function(rust.Playlist playlist)? onOpenPlaylist;

  /// 退回日期列表(本页内部二级层级, 不是 Navigator.pop)
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    // 纯本地日期: 没有在线取数, 直接展示缓存歌单(不进四态)
    if (!entry.remote) return _content(context, const <rust.SongDto>[]);
    return AsyncView<List<rust.SongDto>>(
      load: () => loadSongs(entry.date),
      emptyText: '这一天没有记录',
      loadingBuilder: (_) => const LoadingView(),
      // 空态也要保留头部(返回日期列表 + 当天标题), 所以不用统一空态而是 emptyBuilder
      emptyBuilder: (context) => _content(context, const <rust.SongDto>[]),
      errorBuilder: (_, error, retry) =>
          FullError(message: friendlyError(error), onRetry: retry),
      builder: (context, songs, _) => _content(context, songs),
    );
  }

  Widget _content(BuildContext context, List<rust.SongDto> songs) {
    final playlists = entry.local;
    final openPlaylist = onOpenPlaylist;
    final rows = <Widget>[];
    if (entry.remote) {
      if (songs.isEmpty) {
        rows.add(const ListTile(dense: true, title: Text('这一天没有记录')));
      }
      for (var i = 0; i < songs.length; i++) {
        final s = songs[i];
        rows.add(
          SongRow(
            song: s,
            layout: SongRowLayout.tile,
            indexText: '${i + 1}',
            indexWidth: 22,
            indexAlign: TextAlign.start,
            indexGap: 0,
            coverSize: 40,
            subtitle: SongRowSubtitle.artist,
            showDuration: false,
            // 同「推荐歌曲」页签: 点播不退出历史日推列表
            onTap: s.playable ? () => onPlay(songs, i) : null,
          ),
        );
      }
    }
    if (playlists.isNotEmpty) {
      rows.add(
        ListTile(
          dense: true,
          title: Text(
            '本地缓存的推荐歌单(${playlists.length})',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      );
      for (final pl in playlists) {
        rows.add(
          ListTile(
            leading: CoverArt(url: pl.coverUrl, size: 48, radius: 6),
            title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${pl.trackCount} 首'),
            onTap: openPlaylist == null
                ? null
                : () {
                    Navigator.pop(context);
                    openPlaylist(pl);
                  },
          ),
        );
      }
    }
    return Column(
      children: [
        ListTile(
          dense: true,
          leading: IconButton(
            tooltip: '返回日期列表',
            icon: const Icon(Icons.arrow_back),
            onPressed: onClose,
          ),
          title: Text('${entry.date} 的日推'),
          subtitle: Text(
            entry.remote
                ? (playlists.isEmpty
                      ? '${songs.length} 首'
                      : '${songs.length} 首 · 本地缓存 ${playlists.length} 个歌单')
                : '本地缓存 ${playlists.length} 个歌单',
          ),
        ),
        const Divider(height: 1),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }
}

/// 在线日期 + 本地缓存按日期合并去重(同一天只留一行), 日期倒序.
List<_HistoryEntry> _merge(List<String> remote, List<DailyCacheDay> local) {
  final byDate = <String, _HistoryEntry>{};
  for (final raw in remote) {
    final date = raw.trim();
    if (date.isEmpty) continue;
    byDate[date] = _HistoryEntry(date: date, remote: true, local: const []);
  }
  for (final day in local) {
    final existing = byDate[day.date];
    byDate[day.date] = _HistoryEntry(
      date: day.date,
      remote: existing?.remote ?? false,
      local: day.playlists,
    );
  }
  return byDate.values.toList()..sort((a, b) => b.date.compareTo(a.date));
}

String _subtitleOf(_HistoryEntry entry) {
  if (entry.remote) {
    return entry.hasLocal ? '查看这一天的每日推荐(含本地缓存歌单)' : '查看这一天的每日推荐';
  }
  return '本地缓存的每日推荐歌单';
}

/// 「本地」标记: 这一天的内容来自本地缓存(设置里关掉缓存后不会出现).
class _LocalBadge extends StatelessWidget {
  const _LocalBadge();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '本地',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
    );
  }
}
