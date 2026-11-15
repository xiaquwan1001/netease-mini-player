import 'package:flutter/material.dart';

import '../rust/api.dart' as rust;
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
  required void Function(List<rust.SongDto> songs, int index) onPlaySongs,
  required void Function(rust.Playlist playlist) onOpenPlaylist,
  SongListLoader? loadSongs,
  PlaylistListLoader? loadPlaylists,
  DateListLoader? loadHistoryDates,
  HistorySongsLoader? loadHistorySongs,
  LocalDaysLoader? loadLocalDays,
}) {
  final songs = loadSongs ?? rust.dailyRecommendSongs;
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
        onPlaySongs: onPlaySongs,
        onOpenPlaylist: onOpenPlaylist,
      ),
    ),
  );
}

/// 每日推荐全页(原 showDiscoverSheet 的弹层内容)。
class DailyRecommendPage extends StatelessWidget {
  const DailyRecommendPage({
    super.key,
    required this.loadSongs,
    required this.loadPlaylists,
    required this.loadHistoryDates,
    required this.loadHistorySongs,
    required this.onPlaySongs,
    required this.onOpenPlaylist,
    this.loadLocalDays,
  });

  final SongListLoader loadSongs;
  final PlaylistListLoader loadPlaylists;
  final DateListLoader loadHistoryDates;
  final HistorySongsLoader loadHistorySongs;

  /// 本地缓存的每日推荐歌单(设置里关掉缓存时为 null: 历史日推只列在线日期)
  final LocalDaysLoader? loadLocalDays;
  final void Function(List<rust.SongDto> songs, int index) onPlaySongs;
  final void Function(rust.Playlist playlist) onOpenPlaylist;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('每日推荐'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '推荐歌曲'),
              Tab(text: '推荐歌单'),
              Tab(text: '历史日推'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            DailySongsTab(load: loadSongs, onPlay: onPlaySongs),
            DailyPlaylistsTab(load: loadPlaylists, onOpen: onOpenPlaylist),
            HistoryTab(
              loadDates: loadHistoryDates,
              loadSongs: loadHistorySongs,
              loadLocalDays: loadLocalDays,
              onOpenPlaylist: onOpenPlaylist,
              onPlay: onPlaySongs,
            ),
          ],
        ),
      ),
    );
  }
}
