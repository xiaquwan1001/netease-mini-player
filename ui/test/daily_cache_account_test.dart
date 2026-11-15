import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/daily_cache.dart';
import 'package:minincm/src/rust/api.dart' as rust;

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

/// 每日推荐缓存按账号隔离(2026-11 隐私修复)的回归:
/// A 的日推清单绝不能被 B 读到, 登出/切号清掉的是**上一个账号**的目录。
void main() {
  late Directory tmp;
  late DateTime clock;
  DateTime now() => clock;

  late int fetchCount;
  late List<rust.Playlist> fetched;

  Future<List<rust.Playlist>> doFetch() async {
    fetchCount += 1;
    return fetched;
  }

  DailyPlaylistCache cacheFor(String accountKey) =>
      DailyPlaylistCache(dataDir: tmp.path, accountKey: accountKey);

  /// 旧布局(无账号维度)的顶层目录。
  Directory legacyRoot() => Directory('${tmp.path}/cache/daily-playlists');

  List<String> names(Directory dir) {
    if (!dir.existsSync()) return const [];
    return dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('minincm-daily-cache-uid');
    addTearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });
    clock = DateTime(2026, 3, 10, 9, 30);
    fetchCount = 0;
    fetched = [_playlist(1, 'A 的每日推荐')];
  });

  test('A 写入 → 切到 B 读到空 ⇒ 必须重新 fetch → 切回 A 仍读到 A 的原清单', () async {
    // A: 落一份当日缓存
    final a = cacheFor('uid-1001');
    final aFirst = await a.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 1);
    expect(aFirst.single.name, 'A 的每日推荐');

    // 切到 B: 同一天, 但目录不同 ⇒ 绝对不能读到 A 的清单
    final b = cacheFor('uid-1002');
    expect(await b.days(), isEmpty, reason: 'B 的历史日推不能含 A 的天');
    fetched = [_playlist(2, 'B 的每日推荐')];
    final bFirst = await b.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 2, reason: 'B 没有缓存, 必须真的联网拉一次');
    expect(bFirst.single.name, 'B 的每日推荐');

    // 切回 A: 读到的还是 A 自己的那份
    final aAgain = await a.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 2, reason: '切回 A 命中 A 自己的缓存');
    expect(aAgain.single.name, 'A 的每日推荐');

    // 两个账号各有自己的当日文件, 且 days() 互不串
    expect(names(a.dir), ['2026-03-10.json']);
    expect(names(b.dir), ['2026-03-10.json']);
    expect(
      names(legacyRoot()).where((n) => n.endsWith('.json')),
      isEmpty,
      reason: '日期文件只在账号子目录里, 根目录不该再落散文件',
    );
    expect((await a.days()).single.playlists.single.name, 'A 的每日推荐');
    expect((await b.days()).single.playlists.single.name, 'B 的每日推荐');
  });

  test('未登录(anonymous)与登录账号互不可见', () async {
    final anon = cacheFor(DailyPlaylistCache.anonymousKey);
    await anon.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 1);

    final mine = cacheFor('uid-2002');
    fetched = [_playlist(5, '登录后的推荐')];
    final logged = await mine.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 2, reason: '匿名的那份不能当成登录账号的缓存');
    expect(logged.single.name, '登录后的推荐');

    final anonAgain = await anon.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 2);
    expect(anonAgain.single.name, 'A 的每日推荐');
  });

  test('旧布局(无账号维度)的顶层日期文件: 不被读到, 且首次加载就删掉', () async {
    await legacyRoot().create(recursive: true);
    final legacyFile = File('${legacyRoot().path}/2026-03-10.json');
    await legacyFile.writeAsString(
      jsonEncode([
        {
          'id': 999,
          'name': '不知道属于谁的日推',
          'coverUrl': null,
          'trackCount': 30,
          'special': false,
          'subscribed': false,
        },
      ]),
    );
    await File('${legacyRoot().path}/last-cleanup').writeAsString('0');

    final a = cacheFor('uid-3003');
    final loaded = await a.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 1, reason: '旧文件不能当成缓存命中');
    expect(loaded.single.name, 'A 的每日推荐');
    expect(legacyFile.existsSync(), isFalse, reason: '旧布局文件要清掉');
    expect(
      File('${legacyRoot().path}/last-cleanup').existsSync(),
      isFalse,
      reason: '旧的 last-cleanup 标记同属旧布局, 一并清掉',
    );
    expect(
      File('${legacyRoot().path}/legacy-purged').existsSync(),
      isTrue,
      reason: '清理只做一次, 留标记',
    );
    // 账号目录之外没有散落的日期文件
    expect(
      names(legacyRoot())
          .where((n) => RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(n)),
      isEmpty,
    );
  });

  test('旧布局标记写入后不再重复扫目录, 之后新出现的顶层文件也不当缓存', () async {
    await legacyRoot().create(recursive: true);
    final a = cacheFor('uid-3004');
    await a.load(fetch: doFetch, keepDays: 7, now: now);
    expect(File('${legacyRoot().path}/legacy-purged').existsSync(), isTrue);

    // 标记之后才出现的顶层文件(老版本回滚/手拷贝): 读不到就当没有
    final stray = File('${legacyRoot().path}/2026-03-10.json');
    await stray.writeAsString('[]');
    final again = await a.load(fetch: doFetch, keepDays: 7, now: now);
    expect(fetchCount, 1, reason: '命中的是账号目录里的缓存');
    expect(again.single.name, 'A 的每日推荐');
    expect(stray.existsSync(), isTrue, reason: '标记之后不再扫, 留着也无害');
  });

  test('purgeAccount 只删指定账号目录, 别的账号与根目录都不动', () async {
    final a = cacheFor('uid-4001');
    final b = cacheFor('uid-4002');
    await a.load(fetch: doFetch, keepDays: 7, now: now);
    fetched = [_playlist(2, 'B 的每日推荐')];
    await b.load(fetch: doFetch, keepDays: 7, now: now);
    expect(a.dir.existsSync(), isTrue);
    expect(b.dir.existsSync(), isTrue);

    expect(
      await DailyPlaylistCache.purgeAccount(
        dataDir: tmp.path,
        accountKey: 'uid-4001',
      ),
      isTrue,
    );
    expect(a.dir.existsSync(), isFalse, reason: '登出/切号清的是上一个账号');
    expect(b.dir.existsSync(), isTrue, reason: '当前账号的缓存不能被误删');
    expect(legacyRoot().existsSync(), isTrue);
    // 再清一次(目录已不存在)也算成功, 不抛
    expect(
      await DailyPlaylistCache.purgeAccount(
        dataDir: tmp.path,
        accountKey: 'uid-4001',
      ),
      isTrue,
    );
    expect(await a.days(), isEmpty);
  });

  test('purgeAll 清掉所有账号目录(清除本机凭据这类隐私操作)', () async {
    await cacheFor('uid-5001').load(fetch: doFetch, keepDays: 7, now: now);
    await cacheFor(DailyPlaylistCache.anonymousKey)
        .load(fetch: doFetch, keepDays: 7, now: now);
    expect(await DailyPlaylistCache.purgeAll(dataDir: tmp.path), isTrue);
    expect(legacyRoot().existsSync(), isFalse);
    expect(names(legacyRoot()), isEmpty);
  });

  test('accountKeyFor: 有 uid 用 uid-<n>, 未登录/未知用匿名', () {
    expect(DailyPlaylistCache.accountKeyFor(BigInt.from(42)), 'uid-42');
    expect(
      DailyPlaylistCache.accountKeyFor(BigInt.zero),
      DailyPlaylistCache.anonymousKey,
    );
  });

  test('账号键被消毒成单一路径片段: 带分隔符/.. 都不会拼出上层目录', () {
    final root = legacyRoot();
    for (final raw in ['../../evil', 'a/b', '..', '', 'uid 1']) {
      final cache = DailyPlaylistCache(dataDir: tmp.path, accountKey: raw);
      expect(cache.accountKey, isNot(contains('/')));
      expect(cache.accountKey, isNot(anyOf('.', '..', '')));
      expect(
        cache.dir.path.startsWith('${root.path}/'),
        isTrue,
        reason: 'raw=$raw 不能让缓存目录跑出 cache/daily-playlists',
      );
    }
    expect(
      DailyPlaylistCache(dataDir: tmp.path, accountKey: '..').accountKey,
      DailyPlaylistCache.anonymousKey,
    );
    expect(
      DailyPlaylistCache(dataDir: tmp.path, accountKey: 'uid-42').accountKey,
      'uid-42',
    );
  });

  test('keepDays=0 时不建任何目录(账号分区不影响"关缓存就等于没这模块")', () async {
    await cacheFor('uid-6001').load(fetch: doFetch, keepDays: 0, now: now);
    expect(fetchCount, 1);
    expect(legacyRoot().existsSync(), isFalse);
  });
}
