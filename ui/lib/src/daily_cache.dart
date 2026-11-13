import 'dart:convert';
import 'dart:io';

import 'rust/api.dart' as rust;

/// 每日推荐歌单的本地缓存(按天落盘, 保留 N 天)。
///
/// 为什么放在 Dart 侧而不是 Rust: 每日推荐本身要带账号身份, 但"今天这份已经
/// 拿到了"这件事是纯 UI 层的显示状态, 落一份清单就够; 放 Dart 可以完全不碰
/// 网络层, 也让离线冷启动能先出内容。
///
/// 目录布局(都在 Rust 用的同一个 dataDir 下, 双端不依赖平台插件):
/// - `<dataDir>/cache/daily-playlists/YYYY-MM-DD.json`: 当天的歌单清单
/// - `<dataDir>/cache/daily-playlists/last-cleanup`: 上次清理时间(epoch ms)
///
/// 文件里只存渲染必需的字段, 不含 device_id / cookie / token 之类凭据。
class DailyPlaylistCache {
  DailyPlaylistCache({required this.dataDir});

  final String dataDir;

  /// 缓存目录: `<dataDir>/cache/daily-playlists`
  Directory get dir => Directory('$dataDir/cache/daily-playlists');

  /// 清理标记文件: 与日期文件同目录, 但文件名不匹配日期模式, 不会被 [cleanup] 删掉。
  static const String _cleanupFile = 'last-cleanup';

  /// 只认 `YYYY-MM-DD.json`: 目录里可能还有 .tmp、别的模块的附属文件,
  /// 通配删除会误伤。
  static final RegExp _dayFile = RegExp(r'^(\d{4})-(\d{2})-(\d{2})\.json$');

  /// 取当日歌单: 今天已有缓存就直接读, 否则调 [fetch] 并写入。
  ///
  /// [keepDays] <= 0 表示关闭缓存(直接透传 fetch, 不读不写)。
  /// [now] 供测试注入(判断"今天"以及日期文件的命名)。
  Future<List<rust.Playlist>> load({
    required Future<List<rust.Playlist>> Function() fetch,
    required int keepDays,
    DateTime Function()? now,
  }) async {
    if (keepDays <= 0) {
      // 用户关了缓存: 一次多余的读写都不要, 行为与没有这个模块完全一致。
      return fetch();
    }

    final clock = now ?? DateTime.now;
    final file = _fileFor(clock());

    final cached = await _read(file);
    if (cached != null) {
      // 命中即返回, 不再 fetch: 每日推荐一天内不变, 省一次网络与风控风险。
      return cached;
    }

    // 无缓存(或缓存已损坏被丢弃)才真正请求。
    // fetch 失败时**不吞**: 缓存没有兜底内容, 吞掉会让 UI 停在空白页,
    // 抛给调用方才能进 error 四态(重试按钮)。
    final fresh = await fetch();
    await _write(file, fresh);
    return fresh;
  }

  /// 删除早于 keepDays 天的缓存文件, 返回删除个数。keepDays<=0 时清理**全部**缓存。
  ///
  /// 边界按"天"算: keepDays=3 时保留今天及前 3 天, 4 天前(及更早)删除。
  /// 这里不抛异常: 清理是后台顺带做的事, 磁盘只读/文件被占用都不该影响推荐页。
  Future<int> cleanup({required int keepDays, DateTime Function()? now}) async {
    final clock = now ?? DateTime.now;
    final today = _dayStart(clock());
    final cutoff = today.subtract(Duration(days: keepDays));

    var removed = 0;
    try {
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final day = _parseDayFile(entity.path);
          if (day == null) continue;
          final stale = keepDays <= 0 || day.isBefore(cutoff);
          if (!stale) continue;
          if (await _deleteQuietly(entity)) removed += 1;
        }
      }
    } on FileSystemException {
      // 列目录失败(权限/磁盘)时保留已删计数, 不影响调用方。
    }

    await _markCleaned(clock());
    return removed;
  }

  /// 上次清理时间(没有则 null), 存在 `<dir>/last-cleanup`(epoch ms)。
  Future<DateTime?> lastCleanup() async {
    try {
      final file = File('${dir.path}/$_cleanupFile');
      if (!await file.exists()) return null;
      final ms = int.tryParse((await file.readAsString()).trim());
      if (ms == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    } on FileSystemException {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  File _fileFor(DateTime at) => File('${dir.path}/${_dayName(at)}.json');

  static String _dayName(DateTime at) {
    final y = at.year.toString().padLeft(4, '0');
    final m = at.month.toString().padLeft(2, '0');
    final d = at.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static DateTime _dayStart(DateTime at) => DateTime(at.year, at.month, at.day);

  /// 从文件名解析日期(本地时区零点); 不匹配返回 null。
  static DateTime? _parseDayFile(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final match = _dayFile.firstMatch(name);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  /// 读缓存; 缺失/损坏/旧格式都返回 null(并顺手删掉坏文件)。
  ///
  /// 之所以删: 不删的话每次冷启动都会重新解析同一个坏文件, 而 user 手改过的
  /// 文件永远不会自己好起来。
  Future<List<rust.Playlist>?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) {
        throw const FormatException('daily playlist cache: not a list');
      }
      return decoded.map(_fromJson).toList(growable: false);
    } catch (_) {
      // 解析失败/字段缺失/半截写入: 一律当没缓存, 回落到 fetch。
      await _deleteQuietly(file);
      return null;
    }
  }

  /// 原子写: 先写 .tmp 再 rename, 避免进程被杀留下半截 JSON 被当成有效缓存。
  Future<void> _write(File file, List<rust.Playlist> playlists) async {
    final tmp = File('${file.path}.tmp');
    try {
      await dir.create(recursive: true);
      await tmp.writeAsString(
        jsonEncode(playlists.map(_toJson).toList(growable: false)),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (_) {
      // 落盘失败(磁盘满/只读)不该让推荐页报错: 本次结果照常返回给 UI。
      await _deleteQuietly(tmp);
    }
  }

  static Map<String, Object?> _toJson(rust.Playlist playlist) => {
    'id': playlist.id.toInt(),
    'name': playlist.name,
    'coverUrl': playlist.coverUrl,
    'trackCount': playlist.trackCount.toInt(),
    'special': playlist.special,
    'subscribed': playlist.subscribed,
  };

  /// 字段缺失/类型不对一律抛 [FormatException], 由 [_read] 转成"无缓存"。
  ///
  /// id / trackCount 容忍字符串形式: 手改文件时把它们写成 "123" 很常见,
  /// 没必要因此丢掉整天缓存。
  static rust.Playlist _fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('daily playlist cache: item not an object');
    }
    final id = _bigInt(raw['id']);
    final trackCount = _bigInt(raw['trackCount']);
    final name = raw['name'];
    final special = raw['special'];
    final subscribed = raw['subscribed'];
    final coverUrl = raw['coverUrl'];
    if (id == null || trackCount == null) {
      throw const FormatException('daily playlist cache: bad id/trackCount');
    }
    if (name is! String || special is! bool || subscribed is! bool) {
      throw const FormatException('daily playlist cache: missing fields');
    }
    if (coverUrl != null && coverUrl is! String) {
      throw const FormatException('daily playlist cache: bad coverUrl');
    }
    return rust.Playlist(
      id: id,
      name: name,
      coverUrl: coverUrl as String?,
      trackCount: trackCount,
      special: special,
      subscribed: subscribed,
    );
  }

  static BigInt? _bigInt(Object? raw) {
    if (raw is int) return BigInt.from(raw);
    if (raw is String) return BigInt.tryParse(raw);
    return null;
  }

  static Future<bool> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
        return true;
      }
    } on FileSystemException {
      // 删不掉就算了: 下次读还是会走"损坏回落 fetch"这条路径。
    }
    return false;
  }

  Future<void> _markCleaned(DateTime at) async {
    try {
      await dir.create(recursive: true);
      await File('${dir.path}/$_cleanupFile')
          .writeAsString('${at.millisecondsSinceEpoch}', flush: true);
    } on FileSystemException {
      // 标记失败只影响诊断, 不影响缓存本身。
    }
  }
}
