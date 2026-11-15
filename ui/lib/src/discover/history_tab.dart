import 'package:flutter/material.dart';

import '../cover_art.dart';
import '../daily_cache.dart';
import '../error_views.dart' show FullError;
import '../net_retry.dart';
import '../rust/api.dart' as rust;
import '../state_views.dart';
import 'discover_song_row.dart' show DiscoverSongRow;
import 'discover_types.dart';

/// 「历史日推」页签: 在线日期 + 本地缓存按日期合并去重, 内部还有一层
/// "某一天的日推"二级页(返回键先回日期列表, 见 [PopScope]).
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
  List<String>? _remoteDates;
  List<DailyCacheDay> _localDays = const [];

  /// 在线历史日推的错误: 本地还有内容时降级成列表顶部一行提示, 不整屏报错
  String? _remoteError;

  String? _error;
  Future<void> Function()? _retry;

  /// 选中的日期(非空时展示那一天的曲目/本地歌单)
  _HistoryEntry? _selected;
  List<rust.SongDto>? _songs;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadDates();
  }

  /// 在线日期与本地缓存并行加载: 本地读盘失败只是"少几行", 不能拖垮整页.
  Future<void> _loadDates() async {
    setState(() {
      _error = null;
      _retry = _loadDates;
    });
    final localLoader = widget.loadLocalDays;
    final localFuture = localLoader == null
        ? Future<List<DailyCacheDay>>.value(const <DailyCacheDay>[])
        : localLoader().catchError((_) => const <DailyCacheDay>[]);
    String? remoteError;
    List<String>? dates;
    try {
      dates = await retryNetwork(widget.loadDates);
    } catch (e) {
      remoteError = friendlyError(e);
    }
    final local = await localFuture;
    if (!mounted) return;
    setState(() {
      _remoteDates = dates;
      _localDays = local;
      _remoteError = remoteError;
      // 在线侧失败且本地也没有缓存时才整屏报错(带重试按钮)。
      _error = (dates == null && local.isEmpty) ? remoteError : null;
    });
  }

  /// 打开某一天. 在线日期取曲目; 纯本地日期直接展示缓存的推荐歌单.
  Future<void> _openDay(_HistoryEntry entry) async {
    setState(() {
      _selected = entry;
      _songs = null;
      _error = null;
      _retry = null;
    });
    if (!entry.remote) return;
    try {
      final songs = await retryNetwork(() => widget.loadSongs(entry.date));
      if (!mounted || _selected != entry) return;
      setState(() => _songs = songs);
    } catch (e) {
      if (!mounted || _selected != entry) return;
      setState(() {
        _error = friendlyError(e);
        _retry = () => _openDay(entry);
      });
    }
  }

  void _closeDay() {
    setState(() {
      _selected = null;
      _songs = null;
      _error = null;
      _retry = null;
    });
  }

  /// 在线日期 + 本地缓存按日期合并去重(同一天只留一行), 日期倒序.
  static List<_HistoryEntry> _merge(
    List<String> remote,
    List<DailyCacheDay> local,
  ) {
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

  static String _subtitleOf(_HistoryEntry entry) {
    if (entry.remote) {
      return entry.hasLocal ? '查看这一天的每日推荐(含本地缓存歌单)' : '查看这一天的每日推荐';
    }
    return '本地缓存的每日推荐歌单';
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // 审查 P1-7.14: 「某一天的日推」是本页内部的二级层级,
    // 系统返回键 / AppBar 返回箭头都应先退回日期列表, 而不是直接关掉整页。
    return PopScope(
      canPop: _selected == null,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _selected == null) return;
        _closeDay();
      },
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final selected = _selected;
    if (selected != null) return _buildDay(context, selected);
    if (_error != null) {
      final retry = _retry;
      return retry == null
          ? const SizedBox.shrink()
          : FullError(message: _error!, onRetry: retry);
    }
    final remote = _remoteDates;
    // 在线日期没回来、本地也还没读到、也没有错误: 首屏加载态
    if (remote == null && _localDays.isEmpty && _remoteError == null) {
      return const LoadingView();
    }
    final entries = _merge(remote ?? const [], _localDays);
    if (entries.isEmpty) {
      return const EmptyView(
        icon: Icons.vpn_key_outlined,
        title: '最近 5 次日推仅黑胶 VIP 可见\n(开通后明天再来就会出现在这里)',
      );
    }
    final hasRemoteError = _remoteError != null;
    // 非分页: 在线最近 5 次 + 本地缓存天, 条数有限
    return ListView.separated(
      itemCount: entries.length + (hasRemoteError ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (hasRemoteError && i == 0) {
          return ListTile(
            leading: const Icon(Icons.cloud_off_outlined),
            title: const Text('在线历史日推获取失败'),
            subtitle: Text(_remoteError!),
            trailing: TextButton(
              onPressed: _loadDates,
              child: const Text('重试'),
            ),
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
          onTap: () => _openDay(entry),
        );
      },
    );
  }

  Widget _buildDay(BuildContext context, _HistoryEntry entry) {
    if (_error != null) {
      final retry = _retry;
      return retry == null
          ? const SizedBox.shrink()
          : FullError(message: _error!, onRetry: retry);
    }
    final songs = _songs;
    if (entry.remote && songs == null) {
      return const LoadingView();
    }
    final playlists = entry.local;
    final openPlaylist = widget.onOpenPlaylist;
    final rows = <Widget>[];
    if (entry.remote) {
      final list = songs ?? const <rust.SongDto>[];
      if (list.isEmpty) {
        rows.add(const ListTile(dense: true, title: Text('这一天没有记录')));
      }
      for (var i = 0; i < list.length; i++) {
        final s = list[i];
        rows.add(
          DiscoverSongRow(
            song: s,
            index: i + 1,
            // 同「推荐歌曲」页签: 点播不退出历史日推列表
            onTap: s.playable ? () => widget.onPlay(list, i) : null,
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
            onPressed: _closeDay,
          ),
          title: Text('${entry.date} 的日推'),
          subtitle: Text(
            entry.remote
                ? (playlists.isEmpty
                      ? '${songs!.length} 首'
                      : '${songs!.length} 首 · 本地缓存 ${playlists.length} 个歌单')
                : '本地缓存 ${playlists.length} 个歌单',
          ),
        ),
        const Divider(height: 1),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }
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
