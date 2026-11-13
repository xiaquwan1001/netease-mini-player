import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/daily_cache.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// 造一个歌单(只需要渲染字段)。
rust.Playlist _playlist(int id, String name) => rust.Playlist(
  id: BigInt.from(id),
  name: name,
  coverUrl: 'https://p1.music.126.net/$id.jpg',
  trackCount: BigInt.from(30),
  special: false,
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
    cache = DailyPlaylistCache(dataDir: tmp.path);
    clock = DateTime(2026, 3, 10, 9, 30);
    fetchCount = 0;
    fetched = [_playlist(1, '每日推荐')];
    fetchError = null;
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

  test('落盘 JSON 只含渲染字段且不含凭据', () async {
    await cache.load(fetch: doFetch, keepDays: 3, now: now);
    final file = File('${cache.dir.path}/2026-03-10.json');
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    expect(decoded, hasLength(1));
    final item = decoded.single as Map<String, dynamic>;
    expect(item.keys.toSet(), {
      'id',
      'name',
      'coverUrl',
      'trackCount',
      'special',
      'subscribed',
    });
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

  test('缓存 JSON 损坏 ⇒ 删文件并回落 fetch', () async {
    await cache.load(fetch: doFetch, keepDays: 3, now: now);
    final file = File('${cache.dir.path}/2026-03-10.json');
    await file.writeAsString('{"oops": [1,2,');

    fetched = [_playlist(9, '重新拉到的推荐')];
    final fixed = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 2, reason: '坏缓存必须回落 fetch');
    expect(fixed.single.name, '重新拉到的推荐');
    // 坏文件被覆盖成新内容, 不会残留
    expect(await file.exists(), isTrue);
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    expect((decoded.single as Map<String, dynamic>)['name'], '重新拉到的推荐');
  });

  test('缓存字段缺失/旧格式 ⇒ 删文件并回落 fetch', () async {
    await cache.dir.create(recursive: true);
    final file = File('${cache.dir.path}/2026-03-10.json');
    // 旧格式: 只有 id/name, 缺 trackCount/special/subscribed
    await file.writeAsString('[{"id":1,"name":"旧格式"}]');

    final fixed = await cache.load(fetch: doFetch, keepDays: 3, now: now);
    expect(fetchCount, 1);
    expect(fixed.single.name, '每日推荐');
    final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
    expect((decoded.single as Map<String, dynamic>)['name'], '每日推荐');
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
}
