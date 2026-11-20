import 'dart:convert';
import 'dart:io';

import 'playback_state.dart' show songFromJson, songToJson;
import 'rust/api_all.dart' as rust;

/// 磁盘上某一天的每日推荐缓存(「历史日推」里合并展示用)。
///
/// 2026-11: 除推荐**歌单**外补上推荐**单曲**(问题⑤), 两者同一天写同一个文件。
/// [songs] 为空的语义要看来源: 旧格式文件(v1)里**根本没有单曲这一节**,
/// 读出来是空表; 新格式文件(v2)里 `songs: []` 表示"当天确实没取到曲目"
/// (当天已拉过, 不该再联网)。
class DailyCacheDay {
  const DailyCacheDay({
    required this.date,
    required this.playlists,
    this.songs = const <rust.SongDto>[],
  });

  /// `YYYY-MM-DD`(本地时区), 与历史日推接口返回的日期串同一格式。
  final String date;

  final List<rust.Playlist> playlists;

  /// 当天缓存的推荐单曲(按写入顺序; 已按 id 去重)。
  final List<rust.SongDto> songs;

  /// 歌单与单曲都没有: 这种天不该在历史列表里凭空出现一行。
  bool get isEmpty => playlists.isEmpty && songs.isEmpty;
}

/// 每日推荐(歌单 + 单曲)的本地缓存(按天落盘, 保留 N 天)。
///
/// 为什么放在 Dart 侧而不是 Rust: 每日推荐本身要带账号身份, 但"今天这份已经
/// 拿到了"这件事是纯 UI 层的显示状态, 落一份清单就够; 放 Dart 可以完全不碰
/// 网络层, 也让离线冷启动能先出内容。
///
/// 目录布局(都在 Rust 用的同一个 dataDir 下, 双端不依赖平台插件):
/// - `<dataDir>/cache/daily-playlists/<账号键>/YYYY-MM-DD.json`: 当天的歌单 + 单曲
/// - `<dataDir>/cache/daily-playlists/<账号键>/last-cleanup`: 上次清理时间(epoch ms)
///
/// **文件格式**: v2 = `{"version":2,"playlists":[...],"songs":[...]}`;
/// v1 = 顶层裸数组(只有歌单, 2026-11 之前的版本写的)。读取**两种都认**:
/// v1 读成"歌单已知、单曲未知", 下次取到单曲时**原地升成 v2**, 不删用户已有数据。
/// 单曲里只留渲染 + 点播必需字段(见 `playback_state.dart` 的 `songToJson`):
/// id/名字/艺人/专辑/时长/封面/版权标记, 直链与时链一律不落盘,
/// 也不含 device_id / cookie / token 之类凭据。
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
/// **「历史日推每天内容重复」的判据(2026-11 问题④)**: 查过磁盘上的真实缓存
/// (uid-1822714196: 11-17 / 11-18 / 11-19 三份, 写入时间各不相同 ⇒ 每天都是真的
/// fetch 过一次, 不是复制): 11-18 与 11-19 的 id / 名字 / 首数**逐条相同**
/// (只有封面 CDN 主机 p3/p4 不同)。也就是说**读写链路没有串天**, 重复来自两处:
/// 1. 上游 `/api/v1/discovery/recommend/resource` 的每日推荐歌单本身就高度稳定
///    (「私人雷达」这类常驻歌单天天在), 客户端只能如实记录当天结果;
/// 2. 我们自己的展示层没有做任何收敛: 同一份清单在历史里逐天整份重复列出,
///    同一天清单内部若有重复 id 也照原样列出。
/// 于是修法是: 写入/读取/合并三处**都按 playlist id 去重**(见 [dedupePlaylists]),
/// 历史页对"和更早某天完全相同"的清单加一句标注(见 `discover/history_tab.dart`),
/// 并且**空天不再伪造一行**(文件在但歌单与单曲都空 ⇒ 不列, 而不是无条件占位)。
class DailyPlaylistCache {
  DailyPlaylistCache({required this.dataDir, required String accountKey})
    : accountKey = _safeSegment(accountKey) {
    // 记下最近一次由外壳接线创建的实例(带 dataDir + 账号键), 供 discover 页的
    // 默认单曲加载器复用同一分区 —— 见 [loadSongsForActive]。
    if (dataDir.isNotEmpty) _active = this;
  }

  final String dataDir;

  /// 账号分区键: `uid-<uid>` 或 [anonymousKey]; 已消毒成单一路径片段。
  final String accountKey;

  /// 未登录时用的账号键。匿名日推是**另一份数据**, 不能和任何登录账号共用目录。
  static const String anonymousKey = 'anonymous';

  /// 当前文件格式版本(v1 是顶层裸数组, 没有这个字段)。
  static const int formatVersion = 2;

  /// 最近一次创建的实例(外壳接线时带真实 dataDir/账号键)。
  ///
  /// 用途只有一个: [loadSongsForActive] 让 `discover/` 的默认单曲加载器能在
  /// **不改动外壳接线**的前提下读写同一分区。null = 还没接线 ⇒ 缓存全透传。
  static DailyPlaylistCache? _active;

  /// 最近一次创建的实例(见 [loadSongsForActive])。
  static DailyPlaylistCache? get active => _active;

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
  ///
  /// 命中缓存时**不重写文件**: 已落盘的单曲一节原样保留(见 [loadSongs])。
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

    final cached = await _readDay(file);
    final cachedPlaylists = cached?.playlists;
    if (cachedPlaylists != null) {
      // 命中即返回, 不再 fetch: 每日推荐一天内不变, 省一次网络与风控风险。
      return cachedPlaylists;
    }

    // 无缓存(或缓存已损坏被丢弃)才真正请求。
    // fetch 失败时**不吞**: 缓存没有兜底内容, 吞掉会让 UI 停在空白页,
    // 抛给调用方才能进 error 四态(重试按钮)。
    final fresh = dedupePlaylists(await fetch());
    // 单曲那一节按原样保留(null = 这一天还没存过单曲, 就继续不存)。
    await _write(file, playlists: fresh, songs: cached?.songs);
    return fresh;
  }

  /// 取当日推荐**单曲**: 今天已有单曲缓存就直接读, 否则调 [fetchSongs] 并写入。
  ///
  /// 与 [load] 共用同一个日期文件, 互不覆盖: 命中一侧不会丢掉另一侧已落盘的内容。
  /// 旧格式(v1, 只有歌单)读到的是"单曲未知", 于是会走一次 fetch 并原地升成 v2 ——
  /// 旧文件不删、旧歌单不丢。
  ///
  /// 与 [load] 同一条纪律: fetch 失败原样抛出, 不用别的天的内容兜底。
  Future<List<rust.SongDto>> loadSongs({
    required Future<List<rust.SongDto>> Function() fetchSongs,
    required int keepDays,
    DateTime Function()? now,
  }) async {
    if (keepDays <= 0) return fetchSongs();

    await _purgeLegacyOnce();

    final clock = now ?? DateTime.now;
    final file = _fileFor(clock());

    final cached = await _readDay(file);
    if (cached != null && cached.songsKnown) {
      return cached.songs;
    }

    final fresh = dedupeSongs(await fetchSongs());
    // 歌单那一节按原样保留(null = 这一天还没存过歌单, 就继续不存)。
    await _write(file, playlists: cached?.playlists, songs: fresh);
    return fresh;
  }

  /// 用 [active] 写/读"今天"的单曲; 没有接线或分区键已过期时**原样透传** [fetch]。
  ///
  /// 为什么要比对账号键: [active] 是进程级静态指针, 切号后若外壳还没来得及重建
  /// 推荐页, 它会短暂指向**上一个账号**的分区 —— 那种时刻宁可少一次缓存, 也不能
  /// 把 B 的日推写进 A 的目录(隐私上等价于串号)。
  static Future<List<rust.SongDto>> loadSongsForActive({
    required Future<List<rust.SongDto>> Function() fetch,
    required int keepDays,
  }) async {
    final cache = _active;
    if (cache == null || keepDays <= 0) return fetch();
    if (await resolveAccountKey() != cache.accountKey) return fetch();
    return cache.loadSongs(fetchSongs: fetch, keepDays: keepDays);
  }

  /// 删除早于 keepDays 天的缓存文件, 返回删除个数。keepDays<=0 时清理**全部**缓存。
  ///
  /// 边界按"天"算: keepDays=3 时保留今天及前 3 天, 4 天前(及更早)删除。
  /// 歌单与单曲在同一个文件里, 所以一次清理两边同时生效。
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
  /// 损坏/旧格式/半截写入的文件由 [_readDay] 顺手删掉并跳过, 不会让整份清单报错:
  /// 这里的结果只用来在 UI 里多列几行, 任何一天读不出来都只是少一行。
  /// **歌单与单曲都空的天不返回**(问题④): 文件存在不等于"这天有内容", 无条件占位
  /// 会让历史里凭空多出一天空白行。
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
        final content = await _readDay(file);
        if (content == null) continue;
        final entry = DailyCacheDay(
          date: _dayName(day),
          playlists: content.playlists ?? const <rust.Playlist>[],
          songs: content.songs,
        );
        if (entry.isEmpty) continue;
        out.add(entry);
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
  // 去重(问题④: 同一份内容不该重复出现在一天/跨天的列表里)
  // ---------------------------------------------------------------------------

  /// 按 id 去重, 保留首次出现的顺序。
  ///
  /// 用在三处: 写入前(上游可能重复返回同一歌单)、读取时(手改文件/旧文件)、
  /// 历史页合并时(在线 + 本地两份来源)。都用同一个函数, 口径不会各写一份。
  static List<rust.Playlist> dedupePlaylists(Iterable<rust.Playlist> src) {
    final seen = <BigInt>{};
    final out = <rust.Playlist>[];
    for (final playlist in src) {
      if (seen.add(playlist.id)) out.add(playlist);
    }
    return out;
  }

  /// 按 id 去重, 保留首次出现的顺序(单曲同理)。
  static List<rust.SongDto> dedupeSongs(Iterable<rust.SongDto> src) {
    final seen = <BigInt>{};
    final out = <rust.SongDto>[];
    for (final song in src) {
      if (seen.add(song.id)) out.add(song);
    }
    return out;
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

  /// 读一天的缓存; 缺失/损坏返回 null(损坏的文件顺手删掉)。
  ///
  /// 之所以删: 不删的话每次冷启动都会重新解析同一个坏文件, 而 user 手改过的
  /// 文件永远不会自己好起来。
  ///
  /// **容错分级**: 歌单解析失败 ⇒ 整天作废(它决定"要不要重新请求", 不能猜);
  /// 单曲逐条容错 ⇒ 坏条目跳过, 不让一首脏歌拖掉当天全部歌单。
  Future<_DayContent?> _readDay(File file) async {
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      // v1: 顶层裸数组 = 只有歌单, 单曲未知(不删, 等下次取到单曲时升 v2)。
      if (decoded is List) {
        return _DayContent(
          playlists: dedupePlaylists(decoded.map(_playlistFromJson)),
          songs: const <rust.SongDto>[],
          songsKnown: false,
        );
      }
      if (decoded is! Map) {
        throw const FormatException('daily playlist cache: not list or object');
      }
      final rawPlaylists = decoded['playlists'];
      final rawSongs = decoded['songs'];
      final playlists = rawPlaylists is List
          ? dedupePlaylists(rawPlaylists.map(_playlistFromJson))
          : null;
      final songsKnown = rawSongs is List;
      final songs = songsKnown
          ? dedupeSongs(rawSongs.map(songFromJson).whereType<rust.SongDto>())
          : const <rust.SongDto>[];
      if (playlists == null && !songsKnown) {
        // 既没歌单也没单曲: 这是一份不认识的文件, 当作损坏处理。
        throw const FormatException('daily playlist cache: empty payload');
      }
      return _DayContent(
        playlists: playlists,
        songs: songs,
        songsKnown: songsKnown,
      );
    } catch (_) {
      // 解析失败/字段缺失/半截写入: 一律当没缓存, 回落到 fetch。
      await _deleteQuietly(file);
      return null;
    }
  }

  /// 原子写: 先写 .tmp 再 rename, 避免进程被杀留下半截 JSON 被当成有效缓存。
  ///
  /// [playlists] / [songs] 传 null 表示"这一节不写"(那一天还没取到这一类内容):
  /// 写成空数组会被读回当成"当天就是空的", 于是永远不再请求。
  Future<void> _write(
    File file, {
    required List<rust.Playlist>? playlists,
    required List<rust.SongDto>? songs,
  }) async {
    final tmp = File('${file.path}.tmp');
    try {
      await dir.create(recursive: true);
      await tmp.writeAsString(
        jsonEncode({
          'version': formatVersion,
          if (playlists != null)
            'playlists': dedupePlaylists(playlists)
                .map(_playlistToJson)
                .toList(growable: false),
          if (songs != null)
            'songs': dedupeSongs(songs).map(songToJson).toList(growable: false),
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (_) {
      // 落盘失败(磁盘满/只读)不该让推荐页报错: 本次结果照常返回给 UI。
      await _deleteQuietly(tmp);
    }
  }

  static Map<String, Object?> _playlistToJson(rust.Playlist playlist) => {
    'id': playlist.id.toInt(),
    'name': playlist.name,
    'coverUrl': playlist.coverUrl,
    'trackCount': playlist.trackCount.toInt(),
    'special': playlist.special,
    'subscribed': playlist.subscribed,
  };

  /// 字段缺失/类型不对一律抛 [FormatException], 由 [_readDay] 转成"无缓存"。
  ///
  /// id / trackCount 容忍字符串形式: 手改文件时把它们写成 "123" 很常见,
  /// 没必要因此丢掉整天缓存。
  static rust.Playlist _playlistFromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('daily playlist cache: item not object');
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

/// 一个日期文件的解析结果。
///
/// [playlists] 用 null 区分"这一节没写"(未知)与"写了但是空", 这个区分决定当天
/// 要不要再联网: 未知 ⇒ 请求; 已知空 ⇒ 就当没有。
class _DayContent {
  const _DayContent({
    required this.playlists,
    required this.songs,
    required this.songsKnown,
  });

  final List<rust.Playlist>? playlists;
  final List<rust.SongDto> songs;

  /// 文件里有没有单曲这一节(v1 旧文件 = false)。
  final bool songsKnown;
}
