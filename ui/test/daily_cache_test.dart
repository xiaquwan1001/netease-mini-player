import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/daily_cache.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

import 'support/fakes.dart';

/// 造一个歌单(只需要渲染字段)。
// 共享工厂 + 缓存口径(每张歌单有自己的封面 URL、30 首、已收藏)。
rust.Playlist _playlist(int id, String name) => fakePlaylist(
  id: id,
  name: name,
  coverUrl: 'https://p1.music.126.net/$id.jpg',
  trackCount: 30,
  subscribed: true,
);

void main() {
  late Directory tmp;
  late DailyPlaylistCache cache;

  /// 假时钟: 数值可变, 模拟跨天/跨周。
  late DateTime clock;
  DateTime now() => clock;

  /// 计数器: 断言"有没有真的走 fetch"。
  late int fetchCount;
  late List<rust.Playlist> fetched;
  late Object? fetchError;

  Future<List<rust.Playlist>> doFetch() async {
    fetchCount += 1;
    final err = fetchError;
    if (err != null) throw err;
    return fetched;
  }

  /// 单曲侧的计数器/假数据(问题⑤的缓存口径与歌单同一套纪律)。
  late int songFetchCount;
  late List<rust.SongDto> songFetched;

  Future<List<rust.SongDto>> doFetchSongs() async {
    songFetchCount += 1;
    return songFetched;
  }

  List<String> cacheFiles() {
    final dir = cache.dir;
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.json'))
        .toList()
      ..sort();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('minincm-daily-cache');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });
    // 账号隔离后构造函数必须带账号键: 这里固定用 A 的键, 分区行为另见
    // daily_cache_account_test.dart。
    cache = DailyPlaylistCache(dataDir: tmp.path, accountKey: 'uid-1');
    clock = DateTime(2026, 3, 10, 9, 30);
    fetchCount = 0;
    fetched = [_playlist(1, '每日推荐')];
    fetchError = null;
    songFetchCount = 0;
    songFetched = [fakeSong(id: 7, name: '晴天')];
  });

  test('首次 load 走 fetch 并落盘; 第二次 load 读缓存不再 fetch', () async {
    final first = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 1);
    expect(first.map((p) => p.name), ['每日推荐']);
    expect(cacheFiles(), ['2026-03-10.json']);

    final second = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 1, reason: '同日第二次必须命中缓存');
    expect(second, first, reason: '读回的歌单字段应与写入时一致');
  });

  test('落盘 JSON 只含渲染字段且不含凭据(v2: 歌单 + 单曲同文件)', () async {
    await cache.load(fetch: doFetch, keepDays: 3, now: now);
    await cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 3, now: now);
    final file = File('${cache.dir.path}/2026-03-10.json');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(decoded['version'], DailyPlaylistCache.formatVersion);
    // 歌单: 只有渲染字段(与 v1 一致), 没有 device_id / cookie / token
    final playlists = decoded['playlists'] as List<dynamic>;
    expect(playlists, hasLength(1));
    final playlist = playlists.single as Map<String, dynamic>;
    expect(playlist.keys.toSet(), {
      'id',
      'name',
      'coverUrl',
      'trackCount',
      'special',
      'subscribed',
    });
    // 单曲: 只留渲染 + 点播必需字段, 直链/凭据一律不落盘
    final songs = decoded['songs'] as List<dynamic>;
    expect(songs, hasLength(1));
    final song = songs.single as Map<String, dynamic>;
    expect(song.keys.toSet(), {
      'id',
      'name',
      'artist',
      'artistId',
      'album',
      'albumId',
      'coverUrl',
      'durationMs',
      'fee',
      'vip',
      'paid',
      'playable',
    });
    expect(song.values.whereType<String>(), isNot(contains('token')));
  });

  test('keepDays=0: 不落盘, 每次都 fetch', () async {
    await cache.load(fetch: doFetch, keepDays: 0, now: now);
    await cache.load(fetch: doFetch, keepDays: 0, now: now);
    expect(fetchCount, 2, reason: '缓存关闭时必须直连 fetch');
    expect(cacheFiles(), isEmpty);
    expect(cache.dir.existsSync(), isFalse, reason: '关闭缓存连目录都不建');
  });

  test('跨天: 注入第二天 ⇒ 重新 fetch 并生成新文件', () async {
    await cache.load(fetch: doFetch, keepDays: 3, now: now);
    clock = DateTime(2026, 3, 11, 8, 0);
    fetched = [_playlist(2, '第二天的推荐')];
    final second = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 2);
    expect(second.single.name, '第二天的推荐');
    expect(cacheFiles(), ['2026-03-10.json', '2026-03-11.json']);
  });

  test('fetch 抛错 + 今日缓存命中 ⇒ 返回缓存(离线可用)', () async {
    final first = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 1);

    fetchError = StateError('网络断了');
    final offline = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(offline, first, reason: '离线时必须回落到当天缓存');
    // 缓存优先 ⇒ 根本不会再调 fetch, 这里一并钉住这个行为
    expect(fetchCount, 1);
  });

  test('fetch 抛错且无可用缓存 ⇒ 错误原样抛出(交给 UI 进 error 四态)', () async {
    fetchError = StateError('网络断了');
    await expectLater(
      cache.load(fetch: doFetch, keepDays: 3, now: now),
      throwsA(isA<StateError>()),
    );
    expect(cacheFiles(), isEmpty);
    // 昨天的缓存不能兜今天: 每日推荐是当日内容, 拿旧的会误导
    fetchError = null;
    clock = DateTime(2026, 3, 11, 9, 0);
    await cache.load(fetch: doFetch, keepDays: 3, now: now);
    fetchError = StateError('网络断了');
    clock = DateTime(2026, 3, 12, 9, 0);
    await expectLater(
      cache.load(fetch: doFetch, keepDays: 3, now: now),
      throwsA(isA<StateError>()),
    );
  });

  // -------------------------------------------------------------------------
  // 问题⑤: 每日推荐**单曲**按天落盘(不再只有歌单)
  // -------------------------------------------------------------------------

  test('单曲: 首次 loadSongs 走 fetch 并落盘; 同日再读命中缓存', () async {
    final first = await cache.loadSongs(
      fetchSongs: doFetchSongs,
      keepDays: 7,
      now: now,
    );
    expect(songFetchCount, 1);
    expect(first.map((s) => s.name), ['晴天']);
    expect(cacheFiles(), ['2026-03-10.json']);

    songFetched = [fakeSong(id: 99, name: '不该被拉到')];
    final second = await cache.loadSongs(
      fetchSongs: doFetchSongs,
      keepDays: 7,
      now: now,
    );
    expect(songFetchCount, 1, reason: '同日第二次必须命中缓存');
    expect(second.single.name, '晴天');
    // 写完再读, 渲染 + 点播字段都要原样回来
    expect(second.single.id, BigInt.from(7));
    expect(second.single.artist, '艺人');
    expect(second.single.playable, isTrue);
  });

  test('歌单与单曲共用一天的同一文件, 互不覆盖', () async {
    await cache.load(fetch: doFetch, keepDays: 7, now: now);
    final songs = await cache.loadSongs(
      fetchSongs: doFetchSongs,
      keepDays: 7,
      now: now,
    );
    expect(songs, hasLength(1));
    // 歌单那一节必须还在(没被单曲写入的清空)
    final afterSongs = await cache.load(
      fetch: () async => throw StateError('不该再 fetch'),
      keepDays: 7,
      now: now,
    );
    expect(afterSongs.single.name, '每日推荐');

    // 反方向: 先有单曲, 再写入歌单, 单曲还在
    clock = DateTime(2026, 3, 11, 8);
    await cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 7, now: now);
    await cache.load(fetch: doFetch, keepDays: 7, now: now);
    final readBack = await cache.loadSongs(
      fetchSongs: () async => throw StateError('不该再 fetch'),
      keepDays: 7,
      now: now,
    );
    expect(readBack.single.name, '晴天');
  });

  test('旧格式(v1 裸数组)兼容: 歌单照读, 单曲未知 ⇒ 取一次后原地升 v2, 旧歌单不丢', () async {
    await cache.dir.create(recursive: true);
    final file = File('${cache.dir.path}/2026-03-10.json');
    // v1: 顶层裸数组, 只有歌单, 没有 songs 字段
    await file.writeAsString(
      jsonEncode([
        {
          'id': 42,
          'name': '旧格式歌单',
          'coverUrl': null,
          'trackCount': 5,
          'special': false,
          'subscribed': false,
        },
      ]),
    );

    final playlists = await cache.load(
      fetch: () async => throw StateError('旧格式的歌单还算数, 不该重新拉'),
      keepDays: 7,
      now: now,
    );
    expect(playlists.single.name, '旧格式歌单', reason: '旧格式文件不能删, 也不能当成没缓存');

    final days = await cache.days();
    expect(days.single.songs, isEmpty, reason: 'v1 文件读成"单曲未知"(空表)');

    // 单曲未知 ⇒ 走一次 fetch 并把文件升成 v2
    await cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 7, now: now);
    expect(songFetchCount, 1);
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(decoded['version'], DailyPlaylistCache.formatVersion);
    expect((decoded['playlists'] as List).single['name'], '旧格式歌单');
    expect((decoded['songs'] as List).single['name'], '晴天');
  });

  test('单曲按 id 去重: 写入时与读取时都不重复', () async {
    songFetched = [
      fakeSong(id: 7, name: '晴天'),
      fakeSong(id: 7, name: '晴天(重复条目)'),
      fakeSong(id: 8, name: '七里香'),
    ];
    final songs = await cache.loadSongs(
      fetchSongs: doFetchSongs,
      keepDays: 7,
      now: now,
    );
    expect(songs.map((s) => s.id), [BigInt.from(7), BigInt.from(8)]);
    expect(songs.first.name, '晴天', reason: '保留首次出现的那条');
  });

  test('歌单按 id 去重: 上游重复返回同一歌单只留一条', () async {
    fetched = [
      _playlist(1, '私人雷达'),
      _playlist(2, '独立乐队'),
      _playlist(1, '私人雷达(重复)'),
    ];
    final playlists = await cache.load(fetch: doFetch, keepDays: 7, now: now);
    expect(playlists.map((p) => p.name), ['私人雷达', '独立乐队']);
    final days = await cache.days();
    expect(days.single.playlists, hasLength(2));
  });

  test('keepDays 清理对歌单+单曲同时生效(同一个日期文件)', () async {
    await cache.dir.create(recursive: true);
    for (final day in ['2026-03-06', '2026-03-07', '2026-03-10']) {
      final file = File('${cache.dir.path}/$day.json');
      await file.writeAsString(
        jsonEncode({
          'version': DailyPlaylistCache.formatVersion,
          'playlists': [
            {
              'id': 1,
              'name': '歌单 $day',
              'coverUrl': null,
              'trackCount': 1,
              'special': false,
              'subscribed': false,
            },
          ],
          'songs': [
            {
              'id': 7,
              'name': '单曲 $day',
              'artist': '艺人',
              'artistId': 1,
              'album': '专辑',
              'albumId': 1,
              'coverUrl': null,
              'durationMs': 1000,
              'fee': 0,
              'vip': false,
              'paid': false,
              'playable': true,
            },
          ],
        }),
      );
    }

    // keepDays=3 ⇒ 保留今天(03-10)及前三天的 03-07, 只删 03-06
    expect(await cache.cleanup(keepDays: 3, now: now), 1);
    final left = await cache.days();
    expect(left.map((d) => d.date), ['2026-03-10', '2026-03-07']);
    expect(left.first.playlists.single.name, '歌单 2026-03-10');
    expect(left.first.songs.single.name, '单曲 2026-03-10');
    expect(left.last.songs.single.name, '单曲 2026-03-07');
  });

  test('days() 带上当天单曲; 歌单与单曲都空的天不列(不伪造行)', () async {
    clock = DateTime(2026, 3, 9, 8);
    await cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 7, now: now);
    clock = DateTime(2026, 3, 10, 9);
    await cache.dir.create(recursive: true);
    // 空内容文件: 以前会被当成"有这一天"列出来
    await File('${cache.dir.path}/2026-03-10.json').writeAsString(
      jsonEncode({
        'version': DailyPlaylistCache.formatVersion,
        'playlists': <Object>[],
        'songs': <Object>[],
      }),
    );

    final days = await cache.days();
    expect(days.map((d) => d.date), ['2026-03-09']);
    expect(days.single.songs.single.name, '晴天');
    expect(days.single.playlists, isEmpty);
    expect(
      File('${cache.dir.path}/2026-03-10.json').existsSync(),
      isTrue,
      reason: '空内容是合法缓存, 不该被删',
    );
  });

  test('keepDays=0 时单曲也不落盘(与歌单同一口径)', () async {
    await cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 0, now: now);
    await cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 0, now: now);
    expect(songFetchCount, 2);
    expect(cache.dir.existsSync(), isFalse);
  });

  test('单曲 fetch 抛错 ⇒ 原样抛出, 且不破坏当天已落盘的歌单', () async {
    await cache.load(fetch: doFetch, keepDays: 7, now: now);
    await expectLater(
      cache.loadSongs(
        fetchSongs: () async => throw StateError('网络断了'),
        keepDays: 7,
        now: now,
      ),
      throwsA(isA<StateError>()),
    );
    final playlists = await cache.load(
      fetch: () async => throw StateError('不该再 fetch'),
      keepDays: 7,
      now: now,
    );
    expect(playlists.single.name, '每日推荐');
  });

  test('缓存 JSON 损坏 ⇒ 删文件并回落 fetch', () async {
    await cache.load(fetch: doFetch, keepDays: 3, now: now);
    final file = File('${cache.dir.path}/2026-03-10.json');
    await file.writeAsString('{"oops": [1,2,');

    fetched = [_playlist(9, '重新拉到的推荐')];
    final fixed = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 2, reason: '坏缓存必须回落 fetch');
    expect(fixed.single.name, '重新拉到的推荐');
    // 坏文件被覆盖成新内容(v2: 歌单 + 单曲同文件), 不会残留
    expect(await file.exists(), isTrue);
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((decoded['playlists'] as List).single['name'], '重新拉到的推荐');
  });

  test('缓存字段缺失/旧格式 ⇒ 删文件并回落 fetch', () async {
    await cache.dir.create(recursive: true);
    final file = File('${cache.dir.path}/2026-03-10.json');
    // 旧格式: 只有 id/name, 缺 trackCount/special/subscribed
    await file.writeAsString('[{"id":1,"name":"旧格式"}]');

    final fixed = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 1);
    expect(fixed.single.name, '每日推荐');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect((decoded['playlists'] as List).single['name'], '每日推荐');
  });

  test('cleanup(3): 删 4 天前(及更早), 保留今天与 3 天内; lastCleanup 可读回', () async {
    await cache.dir.create(recursive: true);
    for (final day in [
      '2026-03-06',
      '2026-03-05',
      '2026-03-07',
      '2026-03-10',
    ]) {
      await File('${cache.dir.path}/$day.json').writeAsString('[]');
    }
    // 非日期文件不该被清理
    await File('${cache.dir.path}/notes.txt').writeAsString('keep me');
    await File('${cache.dir.path}/2026-03-06.json.tmp').writeAsString('{}');

    expect(await cache.lastCleanup(), isNull);

    final removed = await cache.cleanup(keepDays: 3, now: now);
    expect(removed, 2, reason: '只该删 03-05 与 03-06');
    expect(cacheFiles(), ['2026-03-07.json', '2026-03-10.json']);
    expect(File('${cache.dir.path}/notes.txt').existsSync(), isTrue);
    expect(File('${cache.dir.path}/2026-03-06.json.tmp').existsSync(), isTrue);

    final marked = await cache.lastCleanup();
    expect(marked, isNotNull);
    expect(marked!.millisecondsSinceEpoch, clock.millisecondsSinceEpoch);
  });

  test('cleanup(0) 清空全部日期缓存, 目录里其它东西不动', () async {
    await cache.dir.create(recursive: true);
    for (final day in ['2026-03-09', '2026-03-10', '2025-12-31']) {
      await File('${cache.dir.path}/$day.json').writeAsString('[]');
    }
    await File('${cache.dir.path}/notes.txt').writeAsString('keep me');

    final removed = await cache.cleanup(keepDays: 0, now: now);
    expect(removed, 3);
    expect(cacheFiles(), isEmpty);
    expect(File('${cache.dir.path}/notes.txt').existsSync(), isTrue);
    expect(await cache.lastCleanup(), isNotNull);
  });

  test('目录不存在时 cleanup 也不抛, 返回 0', () async {
    expect(await cache.cleanup(keepDays: 3, now: now), 0);
    expect(await cache.lastCleanup(), isNotNull);
  });

  test('days() 列出磁盘上的缓存天(倒序), 坏文件跳过并删除', () async {
    clock = DateTime(2026, 3, 9, 8);
    fetched = [_playlist(1, '九号')];
    await cache.load(fetch: doFetch, keepDays: 7, now: now);
    clock = DateTime(2026, 3, 10, 9);
    fetched = [_playlist(2, '十号')];
    await cache.load(fetch: doFetch, keepDays: 7, now: now);
    await File('${cache.dir.path}/2026-03-08.json').writeAsString('{not json');
    await File('${cache.dir.path}/notes.txt').writeAsString('keep me');

    final days = await cache.days();
    expect(days.map((d) => d.date), ['2026-03-10', '2026-03-09']);
    expect(days.first.playlists.single.name, '十号');
    expect(days.last.playlists.single.name, '九号');
    expect(
      File('${cache.dir.path}/2026-03-08.json').existsSync(),
      isFalse,
      reason: '损坏的日期文件读不出来时顺手删掉',
    );
    expect(File('${cache.dir.path}/notes.txt').existsSync(), isTrue);
  });

  test('目录为空/不存在时 days() 返回空表', () async {
    expect(await cache.days(), isEmpty);
    await cache.dir.create(recursive: true);
    expect(await cache.days(), isEmpty);
  });

  test('并发 load 同一实例不抛异常', () async {
    final results = await Future.wait([
      cache.load(fetch: doFetch, keepDays: 3, now: now),
      cache.load(fetch: doFetch, keepDays: 3, now: now),
      cache.load(fetch: doFetch, keepDays: 3, now: now),
    ]);
    expect(results, hasLength(3));
    expect(results.every((list) => list.single.name == '每日推荐'), isTrue);
    expect(cacheFiles(), ['2026-03-10.json']);
  });

  // -------------------------------------------------------------------------
  // 用户反馈⑥: 索引只增不减 —— 歌单与单曲并发写同一文件也不许互相抹掉
  // -------------------------------------------------------------------------

  test('歌单与单曲并发写同一天: 两节都在, 谁先写都不丢', () async {
    // 冷启动现场: 首页「每日推荐」区块拉歌单, 日推页同时拉单曲 ⇒ 两个日期文件
    // 的读-改-写交错。旧实现后写者用自己那份旧快照整份覆盖 ⇒ 另一节变成 null,
    // 表现为「某天只缓存了歌单 / 只缓存了一两首歌」。现在写入阶段串行 + 锁内重读。
    songFetched = [fakeSong(id: 7, name: '晴天'), fakeSong(id: 8, name: '七里香')];
    await Future.wait([
      cache.load(fetch: doFetch, keepDays: 7, now: now),
      cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 7, now: now),
      cache.load(fetch: doFetch, keepDays: 7, now: now),
      cache.loadSongs(fetchSongs: doFetchSongs, keepDays: 7, now: now),
    ]);

    final decoded = jsonDecode(
      await File('${cache.dir.path}/2026-03-10.json').readAsString(),
    ) as Map<String, dynamic>;
    expect(
      (decoded['playlists'] as List).single['name'],
      '每日推荐',
      reason: '歌单那一节不能被并发的单曲写入抹掉',
    );
    expect((decoded['songs'] as List).map((s) => s['name']), [
      '晴天',
      '七里香',
    ], reason: '单曲那一节不能被并发的歌单写入抹掉');
  });

  test('上游短响应不截断已落盘索引(只增不减)', () async {
    // 场景: 两个调用方同时发起加载(首页区块 + 日推页), 一个拿到完整的 30 首,
    // 另一个拿到上游截断的 2 首。锁 + 单调合并之后, 最终索引必须是两者的并集,
    // 而不是"后写的那个" —— 用户当天不会重新打开日推页, 截断就再也回不来了。
    final full = [for (var i = 1; i <= 30; i++) fakeSong(id: i, name: '歌$i')];
    final short = [fakeSong(id: 1, name: '歌1'), fakeSong(id: 31, name: '新歌31')];

    Future<List<rust.SongDto>> fetchFull() async => full;
    // 让"短响应"晚一点落地, 顺序确定: 先写 30 首, 再合并 2 首。
    Future<List<rust.SongDto>> fetchShort() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return short;
    }

    final results = await Future.wait([
      cache.loadSongs(fetchSongs: fetchFull, keepDays: 7, now: now),
      cache.loadSongs(fetchSongs: fetchShort, keepDays: 7, now: now),
    ]);
    expect(results.first, hasLength(30));
    expect(results.last, hasLength(31), reason: '短响应只做增量补充, 已缓存的不丢');

    final days = await cache.days();
    expect(days.single.songs, hasLength(31));
    expect(days.single.songs.map((s) => s.id).toSet(), hasLength(31));
  });

  test('上游短响应不截断已落盘歌单(只增不减)', () async {
    fetched = [for (var i = 1; i <= 8; i++) _playlist(i, '歌单$i')];
    Future<List<rust.Playlist>> fetchFull() async => fetched;

    Future<List<rust.Playlist>> fetchShort() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return [_playlist(1, '歌单1'), _playlist(9, '歌单9')];
    }

    final results = await Future.wait([
      cache.load(fetch: fetchFull, keepDays: 7, now: now),
      cache.load(fetch: fetchShort, keepDays: 7, now: now),
    ]);
    expect(results.first, hasLength(8));
    expect(results.last, hasLength(9), reason: '新歌单追加, 已有的 8 个不丢');
    expect((await cache.days()).single.playlists, hasLength(9));
  });
}
