import 'package:flutter/material.dart';

import '../app_settings.dart' show AppSettings;
import '../daily_cache.dart' show DailyPlaylistCache;
import '../rust/api_all.dart' as rust;
import 'daily_playlists_tab.dart' show DailyPlaylistsTab;
import 'daily_songs_tab.dart' show DailySongsTab;
import 'discover_types.dart';
import 'history_tab.dart' show HistoryTab;

/// 每日推荐: 推荐歌曲 / 推荐歌单 / 历史日推 三个页签.
/// loadSongs/loadPlaylists/loadHistoryDates 可注入(测试用), 默认走 Rust 接口.
///
/// 审查 §5.6: 3 个列表 + 内部二级层级塞进 72% 高的 sheet 局促, 改为全页
/// [Scaffold](与歌单详情/新歌新碟一致); 行为与注入点不变。
Future<void> showDiscoverPage(
  BuildContext context, {
  required void Function(rust.Playlist playlist) onOpenPlaylist,
  SongListLoader? loadSongs,
  PlaylistListLoader? loadPlaylists,
  DateListLoader? loadHistoryDates,
  HistorySongsLoader? loadHistorySongs,
  LocalDaysLoader? loadLocalDays,
  int initialTab = 0,
}) {
  final songs = loadSongs ?? dailySongsWithCache;
  final playlists = loadPlaylists ?? rust.dailyRecommendPlaylists;
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => DailyRecommendPage(
        loadSongs: songs,
        loadPlaylists: playlists,
        loadHistoryDates: loadHistoryDates ?? rust.historyRecommendDates,
        loadHistorySongs:
            loadHistorySongs ??
            (date) => rust.historyRecommendSongs(date: date),
        loadLocalDays: loadLocalDays,
        onOpenPlaylist: onOpenPlaylist,
        initialTab: initialTab,
      ),
    ),
  );
}

/// 「推荐歌曲」页签的默认加载器: 走到本地日推缓存(歌单 + 单曲同一天一个文件)。
///
/// 为什么要自己拼一层: 外壳只把「推荐歌单」的读取接进了缓存
/// (`AccountActions.dailyPlaylists`), 单曲一直直连 `rust.dailyRecommendSongs`,
/// 于是历史日推里"某一天"只有歌单没有曲目(问题⑤)。这里用
/// [DailyPlaylistCache.loadSongsForActive] 复用外壳已经建好的同一分区
/// (dataDir + 账号键), 不改外壳接线: 打开本页 = 当天(歌单 + 单曲)落一次盘,
/// 当天再进直接读缓存。没有接线/账号键对不上时它原样透传 fetch, 行为与改造前一致。
Future<List<rust.SongDto>> dailySongsWithCache() =>
    DailyPlaylistCache.loadSongsForActive(
      fetch: rust.dailyRecommendSongs,
      keepDays: AppSettings.instance.dailyCacheDays,
    );

/// 每日推荐全页(原 showDiscoverSheet 的弹层内容)。
class DailyRecommendPage extends StatelessWidget {
  const DailyRecommendPage({
    super.key,
    required this.loadSongs,
    required this.loadPlaylists,
    required this.loadHistoryDates,
    required this.loadHistorySongs,
    required this.onOpenPlaylist,
    this.loadLocalDays,
    this.initialTab = 0,
  });

  final SongListLoader loadSongs;
  final PlaylistListLoader loadPlaylists;
  final DateListLoader loadHistoryDates;
  final HistorySongsLoader loadHistorySongs;

  /// 本地缓存的每日推荐歌单(设置里关掉缓存时为 null: 历史日推只列在线日期)
  final LocalDaysLoader? loadLocalDays;
  final void Function(rust.Playlist playlist) onOpenPlaylist;

  /// 打开时落在第几个页签(0 推荐歌曲 / 1 推荐歌单 / 2 历史日推)。
  /// B7「历史日推」快捷动作复用它, 不另开一份页面; 默认 0 = 历史行为。
  final int initialTab;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      initialIndex: initialTab.clamp(0, 2),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('每日推荐'),
          // B3a(2026-11-19 用户反馈): 三个页签原来均分屏宽, 300dp + 1.25 字号下
          // 每格约 100dp, 4 个汉字 + labelPadding(16×2) 放不下 ⇒ 末尾字被裁。
          // 改成自然宽度 + 可横向拖动(TabAlignment.start), labelPadding 收窄到 12,
          // 页签仍由 TabBar 自己管指示器/联动(不换成自写 chip 行)。
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: EdgeInsets.symmetric(horizontal: 12),
            tabs: [
              Tab(text: '推荐歌曲'),
              Tab(text: '推荐歌单'),
              Tab(text: '历史日推'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // 页签内的点播走 PlaybackBridge(队列来源标记为每日推荐, 见标签内部)
            DailySongsTab(load: loadSongs),
            DailyPlaylistsTab(load: loadPlaylists, onOpen: onOpenPlaylist),
            HistoryTab(
              loadDates: loadHistoryDates,
              loadSongs: loadHistorySongs,
              loadLocalDays: loadLocalDays,
              onOpenPlaylist: onOpenPlaylist,
            ),
          ],
        ),
      ),
    );
  }
}
