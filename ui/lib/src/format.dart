/// 跨页共享的展示格式化工具.
///
/// 口径总览(勿混用):
/// - [formatDurationMs]: `mm:ss` 补零, 满(含)一小时 `h:mm:ss`(小时不补零);
///   `song_tile.formatSongDuration` 是它加"负值钳 0"的歌曲行包装.
/// - [formatDurationShort]: `m:ss` 分钟不补零, ≤0 返回空串(新歌页行尾).
/// - [formatDateYmd]: `yyyy-MM-dd` 本地时区(会员到期日/动态日期兜底).
library;

/// 毫秒时长 → `mm:ss`, 超过(含)一小时用 `h:mm:ss`.
///
/// 这是 `detail_page` / `artist_page` / `radio_explore_page` /
/// `podcast.dart` 原来各复制一份的同一套口径.
/// 负值不在此钳制(向零取整后回绕, 如 -5s → 59:55, 测试锁定);
/// 需要钳 0 的调用方(歌曲行)自行包一层.
String formatDurationMs(BigInt ms) {
  final total = (ms ~/ BigInt.from(1000)).toInt();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = m.toString().padLeft(2, '0');
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

/// 毫秒时长 → `m:ss`(分钟不补零, 如 245s → `4:05`); ≤0 返回空串.
///
/// `new_release_page` 新歌行尾的原口径: 无小时位, 超 60 分钟继续累计
/// (3961s → `66:01`), 与 [formatDurationMs] 的补零口径不同.
String formatDurationShort(BigInt ms) {
  if (ms <= BigInt.zero) return '';
  final total = ms.toInt() ~/ 1000;
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}

/// 毫秒时间戳 → `yyyy-MM-dd`(本地时区).
///
/// `vip_page._dateOf`(会员到期日, 上层再包"≤0 → null"语义)与
/// `feed_detail_page.feedRelativeTime`(动态超 30 天的日期兜底)
/// 原各复制一份的同一口径.
/// 一位小数 + 单位, 去掉多余的 `.0`(如 1690.8万 / 3千).
///
/// 原先 `comment_stats_bar._oneDecimal` 与 new_release_page 的粉丝数各写一份,
/// 统一到这里。
String formatOneDecimal(double value, String unit) {
  final text = value.toStringAsFixed(1);
  final trimmed = text.endsWith('.0')
      ? text.substring(0, text.length - 2)
      : text;
  return trimmed + unit;
}

/// 数量级文案(喜欢人数/分享数这类"量级"展示): `999` / `3k+` / `1w+` / `2亿+`.
///
/// 口径与官方三档一致 —— 千以下给准确值, 千/万/亿三档只给**下界 + 加号**
/// (不四舍五入也不给小数), 因为它表达的是"这个数量级", 不是精确计数。
/// 评论数优先用上游自带文案 `CommentStats.commentCountDesc`("100w+"), 没有再走这里。
String formatCountMagnitude(int n) {
  if (n < 0) return '0';
  if (n < 1000) return '$n';
  if (n < 10000) return '${n ~/ 1000}k+';
  if (n < 100000000) return '${n ~/ 10000}w+';
  return '${n ~/ 100000000}亿+';
}

/// 粉丝 / 关注数文案: 万以下原样, 万/亿 一位小数(1922.7万 / 1.9亿).
///
/// 与官方「1923.2万粉丝」同一口径; 与 [formatCountMagnitude] 的区别是
/// 这里要的是**精确到一位小数的展示值**, 不是"量级下界"。
String formatFanCount(BigInt n) {
  final v = n.toInt();
  if (v < 10000) return '$v';
  if (v < 100000000) return formatOneDecimal(v / 10000, '万');
  return formatOneDecimal(v / 100000000, '亿');
}

String formatDateYmd(BigInt ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms.toInt());
  final mm = dt.month.toString().padLeft(2, '0');
  final dd = dt.day.toString().padLeft(2, '0');
  return '${dt.year}-$mm-$dd';
}
