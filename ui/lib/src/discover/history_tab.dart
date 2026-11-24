import 'package:flutter/material.dart';

import '../async_view.dart';
import '../cover_art.dart';
import '../daily_cache.dart';
import '../error_views.dart' show FullError;
import '../net_retry.dart' show friendlyError, retryNetwork;
import '../playback_bridge.dart';
import '../rust/api_all.dart' as rust;
import '../state_views.dart';
import '../song_actions.dart' show SongActionSource;
import '../song_tile.dart' show SongRow;
import 'discover_types.dart';

/// 历史日推的一行: 在线日期 / 本地缓存日期 / 两者都有(合并去重后只留一行).
class _HistoryEntry {
  const _HistoryEntry({
    required this.date,
    required this.remote,
    this.playlists = const <rust.Playlist>[],
    this.songs = const <rust.SongDto>[],
    this.samePlaylistsAs,
    this.repeatedSongIds = const <BigInt>{},
    this.sameSongsAs,
  });

  /// YYYY-MM-DD
  final String date;

  /// 服务端历史日推里有这一天(VIP 才能取到曲目)
  final bool remote;

  /// 这一天本地缓存的推荐歌单(可能为空; 已按 id 去重)
  final List<rust.Playlist> playlists;

  /// 这一天本地缓存的推荐**单曲**(问题⑤)。在线日期不展示它 —— 接口结果更新。
  final List<rust.SongDto> songs;

  /// 本地歌单与**更早的某一天**完全相同(上游日推歌单高度稳定), 值是那天的 YYYY-MM-DD。
  final String? samePlaylistsAs;

  /// 当天曲目里**已在更早的日推里出现过**的曲目 id(2026-11 用户反馈⑥: 日推歌曲
  /// 本身就高度重复, 本地恢复注意事项列表里逐天整份重列)。
  final Set<BigInt> repeatedSongIds;

  /// 当天曲目**整份**与更早某天相同时的那天日期(部分重复看 [repeatedSongIds])。
  final String? sameSongsAs;

  bool get hasLocal => playlists.isNotEmpty || songs.isNotEmpty;

  _HistoryEntry withSamePlaylistsAs(String? date) => _HistoryEntry(
    date: this.date,
    remote: remote,
    playlists: playlists,
    songs: songs,
    samePlaylistsAs: date,
    repeatedSongIds: repeatedSongIds,
    sameSongsAs: sameSongsAs,
  );
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
    this.loadLocalDays,
    this.onOpenPlaylist,
  });

  final DateListLoader loadDates;
  final HistorySongsLoader loadSongs;

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

/// 某一天的日推(二级): 在线日期取曲目, 纯本地日期直接展示缓存的推荐单曲 + 歌单.
class _HistoryDayView extends StatelessWidget {
  const _HistoryDayView({
    super.key,
    required this.entry,
    required this.loadSongs,
    required this.onClose,
    this.onOpenPlaylist,
  });

  final _HistoryEntry entry;
  final HistorySongsLoader loadSongs;
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

  /// 当天头部副标题: 在线日期报接口给的曲目数; 纯本地日期报缓存里的曲目/歌单数。
  String _headerSubtitle(List<rust.SongDto> songs) {
    final playlists = entry.playlists;
    final repeated = entry.remote ? 0 : entry.repeatedSongIds.length;
    final dedupe = repeated == 0 ? '' : ' · $repeated 首与更早重复';
    if (entry.remote) {
      return playlists.isEmpty
          ? '${songs.length} 首'
          : '${songs.length} 首 · 缓存 ${playlists.length} 个歌单';
    }
    final parts = <String>[
      if (songs.isNotEmpty) '${songs.length} 首',
      if (playlists.isNotEmpty) '${playlists.length} 个歌单',
    ];
    return '缓存 ${parts.join(' · ')}$dedupe';
  }

  Widget _content(BuildContext context, List<rust.SongDto> remoteSongs) {
    final playlists = entry.playlists;
    final openPlaylist = onOpenPlaylist;
    // 同一天只出一份曲目(问题④): 在线日期以接口结果为准, 本地缓存里那份是同一天的
    // 旧副本, 两边都列会让「某一天」看起来重复; 只有纯本地日期才用缓存曲目。
    final songs = entry.remote
        ? remoteSongs
        : DailyPlaylistCache.dedupeSongs(entry.songs);
    // 去重口径(2026-11 用户反馈⑥): 本地日期里**与更早的日推重复**的曲目不整行
    // 逐天重列 —— 正常行只留当天新增的, 重复的折叠到一行里(点开仍可播, 内容不丢)。
    final repeatedIds = entry.remote ? const <BigInt>{} : entry.repeatedSongIds;
    final fresh = <rust.SongDto>[
      for (final s in songs)
        if (!repeatedIds.contains(s.id)) s,
    ];
    final duplicated = <rust.SongDto>[
      for (final s in songs)
        if (repeatedIds.contains(s.id)) s,
    ];
    final rows = <Widget>[];
    if (entry.remote) {
      if (songs.isEmpty) {
        rows.add(const ListTile(dense: true, title: Text('这一天没有记录')));
      }
    }
    if (!entry.remote && songs.isNotEmpty) {
      rows.add(
        ListTile(
          dense: true,
          title: Text(
            '缓存的推荐单曲(${songs.length})',
            style: Theme.of(context).textTheme.labelLarge,
          ),
        ),
      );
    }
    Widget songRow(
      rust.SongDto s,
      int i,
      List<rust.SongDto> queue,
      String indexText,
    ) => SongRow.pageIndexed(
      song: s,
      indexText: indexText,
      // 历史日推与「推荐歌曲」页签同一来源: 菜单保留「不感兴趣」
      menuSource: SongActionSource.dailyRecommend,
      // 同「推荐歌曲」页签: 点播不退出历史日推列表
      onTap: s.playable
          ? () => PlaybackBridge.instance.playSongs(
              queue,
              i,
              source: SongActionSource.dailyRecommend,
            )
          : null,
    );
    for (var i = 0; i < fresh.length; i++) {
      // 队列仍是**当天完整曲目**(不只新增那几首), 序号跟当天真实顺序一致。
      final index = songs.indexWhere((s) => s.id == fresh[i].id);
      rows.add(songRow(fresh[i], index, songs, '${index + 1}'));
    }
    if (duplicated.isNotEmpty) {
      final sameAs = entry.sameSongsAs;
      rows.add(
        ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: EdgeInsets.zero,
          leading: const Icon(Icons.filter_alt_outlined, size: 20),
          title: Text(
            '与更早的日推重复的 ${duplicated.length} 首',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          subtitle: sameAs == null
              ? null
              : Text('这一天的曲目与 $sameAs 相同(服务端当天返回的就是这份)'),
          children: [
            for (final s in duplicated)
              songRow(
                s,
                songs.indexWhere((x) => x.id == s.id),
                songs,
                '${songs.indexWhere((x) => x.id == s.id) + 1}',
              ),
          ],
        ),
      );
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
      // 上游日推歌单高度稳定: 与更早某天完全相同时明说, 免得用户以为本地串了号。
      final sameAs = entry.samePlaylistsAs;
      if (sameAs != null) {
        rows.add(
          ListTile(
            dense: true,
            leading: const Icon(Icons.info_outline, size: 18),
            title: Text('推荐歌单与 $sameAs 相同(服务端当天返回的就是这份)'),
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
          subtitle: Text(_headerSubtitle(songs)),
        ),
        const Divider(height: 1),
        Expanded(child: ListView(children: rows)),
      ],
    );
  }
}

/// 在线日期 + 本地缓存按日期合并去重(同一天只留一行), 日期倒序.
///
/// 三条口径(问题④, 根因见 `daily_cache.dart` 头注释):
/// 1. **同一天只出一行**: 在线与本地合成一条;
/// 2. **同一份内容只留一条**: 歌单/单曲合并前按 id 去重(上游会重复返回同一歌单);
/// 3. **不伪造天**: 本地那份歌单与单曲都空的天直接跳过(文件在 ≠ 这天有内容)。
///
/// 另外: 若某天的歌单清单/曲目清单与更早某天完全相同, 记下"跟哪天一样";
/// 曲目还会逐个算"这一首在更早的日推里已出现过"([_HistoryEntry.repeatedSongIds]),
/// 由 UI 折叠成一行 —— 上游的日推本来就高度稳定, 让用户看到这是服务端当天的结果,
/// 而不是本地串了号或重复落了盘。
List<_HistoryEntry> _merge(List<String> remote, List<DailyCacheDay> local) {
  final byDate = <String, _HistoryEntry>{};
  for (final raw in remote) {
    final date = raw.trim();
    if (date.isEmpty || byDate.containsKey(date)) continue;
    byDate[date] = _HistoryEntry(date: date, remote: true);
  }
  for (final day in local) {
    final playlists = DailyPlaylistCache.dedupePlaylists(day.playlists);
    final songs = DailyPlaylistCache.dedupeSongs(day.songs);
    if (playlists.isEmpty && songs.isEmpty) continue;
    final existing = byDate[day.date];
    byDate[day.date] = _HistoryEntry(
      date: day.date,
      remote: existing?.remote ?? false,
      playlists: playlists,
      songs: songs,
    );
  }
  // 升序扫一遍: 每个「歌单指纹」记住最近一次出现的日期, 撞指纹就标出更早那天。
  // 曲目同理: 维护一个"更早已出现过"的 id 集合, 并记住整份撞指纹的那天。
  final lastSeenAt = <String, String>{};
  final lastSeenSongsAt = <String, String>{};
  final seenSongIds = <BigInt>{};
  final merged = <_HistoryEntry>[];
  final dates = byDate.keys.toList()..sort();
  for (final date in dates) {
    final entry = byDate[date]!;
    String? same;
    if (entry.playlists.isNotEmpty) {
      final fingerprint = entry.playlists.map((p) => p.id.toString()).join(',');
      same = lastSeenAt[fingerprint];
      lastSeenAt[fingerprint] = date;
    }
    String? sameSongs;
    Set<BigInt> repeated = const <BigInt>{};
    if (entry.songs.isNotEmpty) {
      final ids = entry.songs.map((s) => s.id).toList(growable: false);
      final fingerprint = ids.join(',');
      sameSongs = lastSeenSongsAt[fingerprint];
      lastSeenSongsAt[fingerprint] = date;
      repeated = {
        for (final id in ids)
          if (seenSongIds.contains(id)) id,
      };
      seenSongIds.addAll(ids);
    }
    final withPlaylists = same == null
        ? entry
        : entry.withSamePlaylistsAs(same);
    merged.add(
      _HistoryEntry(
        date: withPlaylists.date,
        remote: withPlaylists.remote,
        playlists: withPlaylists.playlists,
        songs: withPlaylists.songs,
        samePlaylistsAs: withPlaylists.samePlaylistsAs,
        repeatedSongIds: repeated,
        sameSongsAs: sameSongs,
      ),
    );
  }
  return merged.reversed.toList(growable: false);
}

String _subtitleOf(_HistoryEntry entry) {
  if (entry.remote) {
    return entry.hasLocal ? '查看这一天的每日推荐(含缓存内容)' : '查看这一天的每日推荐';
  }
  final parts = <String>[
    if (entry.songs.isNotEmpty) '${entry.songs.length} 首',
    if (entry.playlists.isNotEmpty) '${entry.playlists.length} 个歌单',
  ];
  final repeated = entry.repeatedSongIds.length;
  final dedupe = repeated == 0 ? '' : ' · $repeated 首与更早重复';
  return '缓存的每日推荐: ${parts.join(' · ')}$dedupe';
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
