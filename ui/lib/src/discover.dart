/// 每日推荐 / 最近听过的公开入口(实现拆在 src/discover/ 下).
///
/// 一页一文件: [showDiscoverPage](三个页签) / [showRecentPage](四个分类),
/// 首页都是全页 [Scaffold]; 加载回调 typedef 在 discover_types.dart。
library;

export 'discover/daily_playlists_tab.dart' show DailyPlaylistsTab;
export 'discover/daily_recommend_page.dart';
export 'discover/daily_songs_tab.dart' show DailySongsTab;
export 'discover/discover_types.dart';
export 'discover/history_tab.dart' show HistoryTab;
export 'discover/recent_played_page.dart';
