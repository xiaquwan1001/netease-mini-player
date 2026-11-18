import 'dart:convert';
import 'dart:io';

import 'rust/api.dart' as rust;

/// 磁盘上某一天的每日推荐歌单缓存(「历史日推」里合并展示用)。
class DailyCacheDay {
  const DailyCacheDay({required this.date, required this.playlists});

  /// `YYYY-MM-DD`(本地时区), 与历史日推接口返回的日期串同一格式。
  final String date;

  final List<rust.Playlist> playlists;
}

/// 每日推荐歌单的本地缓存(按天落盘, 保留 N 天)。
///
/// 为什么放在 Dart 侧而不是 Rust: 每日推荐本身要带账号身份, 但"今天这份已经
/// 拿到了"这件事是纯 UI 层的显示状态, 落一份清单就够; 放 Dart 可以完全不碰
/// 网络层, 也让离线冷启动能先出内容。
///
/// 目录布局(都在 Rust 用的同一个 dataDir 下, 双端不依赖平台插件):
/// - `<dataDir>/cache/daily-playlists/<账号键>/YYYY-MM-DD.json`: 当天的歌单清单
/// - `<dataDir>/cache/daily-playlists/<账号键>/last-cleanup`: 上次清理时间(epoch ms)
///
/// **账号隔离(2026-11 隐私修复)**: 每日推荐是**按账号算**的(日推接口带 uid 上下文,
/// 见 Rust 侧 `read_cache` 的注释), 所以目录必须带账号维度 —— 否则切号后 B 会直接
/// 读到 A 的日推清单。账号键由 [resolveAccountKey] 给出: `uid-<数字 uid>`,
/// 未登录用 [anonymousKey]。登出/切号时由调用方删掉上一个账号的目录(见 [purgeAccount])。
///
/// **旧布局(无账号维度)一律丢弃**: 早期写在 `daily-playlists/` 顶层的
/// `YYYY-MM-DD.json` 属于哪个账号已无从判断, 既不能归给某个 uid 也不能算匿名,
/// 因此 [_purgeLegacyOnce] 首次运行时就地删掉(留 `legacy-purged` 标记, 只扫一遍)。
/// 取舍: 老用户升级后当天的离线缓存会丢一次(进推荐页重新拉), 但绝不会串号。
///
/// 文件里只存渲染必需的字段, 不含 device_id / cookie / token 之类凭据。
class DailyPlaylistCache {
  DailyPlaylistCache({required this.dataDir, required String accountKey})
    : accountKey = _safeSegment(accountKey);

  final String dataDir;

  /// 账号分区键: `uid-<uid>` 或 [anonymousKey]; 已消毒成单一路径片段。
  final String accountKey;

  /// 未登录时用的账号键。匿名日推是**另一份数据**, 不能和任何登录账号共用目录。
  static const String anonymousKey = 'anonymous';

  /// 缓存根目录(所有账号的父目录): `<dataDir>/cache/daily-playlists`
  Directory get root => Directory('$dataDir/cache/daily-playlists');

  /// 当前账号的缓存目录: `<root>/<账号键>`
  Directory get dir => Directory('${root.path}/$accountKey');

  /// 清理标记文件: 与日期文件同目录, 但文件名不匹配日期模式, 不会被 [cleanup] 删掉。
  static const String _cleanupFile = 'last-cleanup';

  /// 旧布局清理标记(放 root, 不含账号信息): 存在即表示顶层旧文件已经扫过一遍。
  static const String _legacyMarker = 'legacy-purged';

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

    // 老布局(无账号维度)的文件先一次性清掉: 它们读不得(不知道属于谁), 也不能留。
    await _purgeLegacyOnce();

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
    // 只走设置页清理的用户也要能把旧布局的残留扫掉。
    await _purgeLegacyOnce();

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

  /// 磁盘上已有缓存的天(按日期倒序), 供「历史日推」合并展示。
  ///
  /// 损坏/旧格式/半截写入的文件由 [_read] 顺手删掉并跳过, 不会让整份清单报错:
  /// 这里的结果只用来在 UI 里多列几行, 任何一天读不出来都只是少一行。
  Future<List<DailyCacheDay>> days() async {
    final out = <DailyCacheDay>[];
    try {
      if (!await dir.exists()) return const [];
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is File && _dayFile.hasMatch(_name(entity.path))) {
          files.add(entity);
        }
      }
      for (final file in files) {
        final day = _parseDayFile(file.path);
        if (day == null) continue;
        final playlists = await _read(file);
        if (playlists == null) continue;
        out.add(DailyCacheDay(date: _dayName(day), playlists: playlists));
      }
    } on FileSystemException {
      // 列目录/读文件失败(权限/磁盘): 返回已读到的部分。
    }
    out.sort((a, b) => b.date.compareTo(a.date));
    return out;
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
  // 账号维度(身份解析 / 清理)
  // ---------------------------------------------------------------------------

  /// 当前账号的缓存分区键: `uid-<uid>`, 未登录或查不到时 [anonymousKey]。
  ///
  /// 身份来源都不触网(纯本地状态), 按可信度排:
  /// 1. `rust.myUid()`: 会话里的 profile, 登录/切号时立刻刷新, 最准;
  /// 2. 账号簿里的 `active` 标记: 离线冷启动、profile 还没同步时兜底
  ///    (账号簿是持久化的, 重启后仍然知道当前是哪个账号);
  /// 3. 都没有 ⇒ 匿名(匿名日推与任何登录账号的数据分开)。
  static Future<String> resolveAccountKey() async {
    return accountKeyFor(await _currentUid());
  }

  /// 账号键的格式定义(`uid-<uid>` / [anonymousKey])。
  /// 需要判断"是不是同一个账号"时用它, 不要在调用方自己拼字符串。
  static String accountKeyFor(BigInt uid) =>
      uid > BigInt.zero ? 'uid-$uid' : anonymousKey;

  static Future<BigInt> _currentUid() async {
    try {
      final uid = await rust.myUid();
      if (uid > BigInt.zero) return uid;
    } catch (_) {
      // FFI 还没初始化/引擎异常: 回落到账号簿, 不把异常抛给推荐页。
    }
    try {
      for (final account in await rust.accounts()) {
        if (account.active) return account.userId;
      }
    } catch (_) {
      // 同上: 查不到就当未登录。
    }
    return BigInt.zero;
  }

  /// 删除指定账号的日推缓存目录(连同里面的 `last-cleanup` 标记)。
  ///
  /// 只删 `<root>/<账号键>` 这一层: 别的账号的目录、root 本身都不动, 所以
  /// 切回老账号只是"要重新拉一次", 不会把别人的数据一起端掉。
  /// 目录本来不存在也算成功; 失败(权限/占用)返回 false 而不抛 —— 登出流程
  /// 不该因为清缓存失败而报错。
  static Future<bool> purgeAccount({
    required String dataDir,
    required String accountKey,
  }) async {
    final target = Directory(
      '$dataDir/cache/daily-playlists/${_safeSegment(accountKey)}',
    );
    try {
      if (!await target.exists()) return true;
      await target.delete(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// 删掉**所有**账号(含匿名)的日推缓存: 设置里"清除本机登录凭据"这类隐私操作。
  static Future<bool> purgeAll({required String dataDir}) async {
    final root = Directory('$dataDir/cache/daily-playlists');
    try {
      if (!await root.exists()) return true;
      await root.delete(recursive: true);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /// 账号键只允许当单一路径片段: 去掉分隔符/空白, `.`/`..` 也不能当键。
  static String _safeSegment(String raw) {
    final cleaned = raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return anonymousKey;
    }
    return cleaned;
  }

  /// 清理**旧布局**(顶层、无账号维度的)日期文件与旧 `last-cleanup`, 只做一次。
  ///
  /// 为什么删而不是留着: 这些文件属于哪个账号无从判断, 读进来就是串号; 留着又
  /// 永久占盘, 因为新布局的 [cleanup] 只扫账号目录, 永远扫不到它们。
  /// `legacy-purged` 标记保证只列一次目录, 之后每次 load 只多一次 `exists()`。
  Future<void> _purgeLegacyOnce() async {
    try {
      if (!await root.exists()) return;
      final marker = File('${root.path}/$_legacyMarker');
      if (await marker.exists()) return;
      await for (final entity in root.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = _name(entity.path);
        final legacy =
            _dayFile.hasMatch(name) ||
            name == _cleanupFile ||
            name == '$_cleanupFile.tmp' ||
            name.endsWith('.json.tmp');
        if (legacy) await _deleteQuietly(entity);
      }
      await marker.writeAsString(
        '${DateTime.now().millisecondsSinceEpoch}',
        flush: true,
      );
    } on FileSystemException {
      // 列目录/写标记失败: 下次 load/cleanup 再试, 不影响本次缓存读写。
    }
  }

  File _fileFor(DateTime at) => File('${dir.path}/${_dayName(at)}.json');

  static String _dayName(DateTime at) {
    final y = at.year.toString().padLeft(4, '0');
    final m = at.month.toString().padLeft(2, '0');
    final d = at.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  static DateTime _dayStart(DateTime at) => DateTime(at.year, at.month, at.day);

  static String _name(String path) => path.split(Platform.pathSeparator).last;

  /// 从文件名解析日期(本地时区零点); 不匹配返回 null。
  static DateTime? _parseDayFile(String path) {
    final match = _dayFile.firstMatch(_name(path));
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
