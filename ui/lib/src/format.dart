/// 跨页共享的展示格式化工具.
///
/// 注意: `song_tile.dart` 的 `formatSongDuration` 是 mm:ss 定长口径
/// (不足一小时也补零到 04:05), 由另一车道维护并有测试锁定, 暂不收编.
library;

/// 毫秒时长 → `mm:ss`, 超过(含)一小时用 `h:mm:ss`.
///
/// 这是 `detail_page` / `artist_page` / `radio_explore_page` /
/// `podcast.dart` 原来各复制一份的同一套口径.
String formatDurationMs(BigInt ms) {
  final total = (ms ~/ BigInt.from(1000)).toInt();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
