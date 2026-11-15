import '../daily_cache.dart' show DailyCacheDay;
import '../rust/api.dart' as rust;

/// 每日推荐/最近听过的加载回调 typedef(页面与测试注入点共用).

typedef SongListLoader = Future<List<rust.SongDto>> Function();
typedef PlaylistListLoader = Future<List<rust.Playlist>> Function();
typedef DateListLoader = Future<List<String>> Function();
typedef HistorySongsLoader = Future<List<rust.SongDto>> Function(String date);

/// 本地缓存的每日推荐歌单(来自 daily_cache.dart); null/不传 = 不合并本地.
typedef LocalDaysLoader = Future<List<DailyCacheDay>> Function();

typedef AlbumListLoader = Future<List<rust.AlbumItem>> Function();
typedef PodcastListLoader = Future<List<rust.PodcastRadio>> Function();
