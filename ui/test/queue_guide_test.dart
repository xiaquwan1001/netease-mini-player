import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/queue.dart';
import 'package:minincm/src/queue_guide.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

import 'support/fakes.dart';

// 2026-11-19 用户反馈 4/5: 心动模式与私人FM 要从「播放顺序」里独立出来。
//
// 现场取证(CLI 直打真接口): `ncm-cli -- raw fm` 连打三次, 每次 **2 首**且互不相同
// ⇒ 以前只取一批就 playSongs, 队列面板里永远只有两首歌, 播完就被 PlayMode 接管。
// 这里的假 loader 按同样的"一次 2 首"口气回数据。

/// 假 FM 服务: 每次调用给下一批(默认每批 2 首), 批次用尽后返回空。
class FakeFm {
  FakeFm(this.batches);

  final List<List<int>> batches;
  int calls = 0;

  Future<List<rust.SongDto>> call() async {
    final i = calls++;
    if (i >= batches.length) return const [];
    return [for (final id in batches[i]) fakeSong(id: id, name: 'FM$id')];
  }
}

void main() {
  group('loadFmBatches', () {
    test('连取 3 批拼成一段队列(接口一次只回 2 首)', () async {
      final fm = FakeFm([
        [1, 2],
        [3, 4],
        [5, 6],
      ]);
      final songs = await loadFmBatches(fm.call);
      expect([for (final s in songs) s.id.toInt()], [1, 2, 3, 4, 5, 6]);
      expect(fm.calls, 3);
    });

    test('不可播的曲目不入队(入队也只会被 playSong 跳过)', () async {
      final songs = await loadFmBatches(
        () async => [
          fakeSong(id: 1, name: '可播'),
          fakeSong(id: 2, name: '无版权', playable: false),
        ],
        batches: 1,
      );
      expect([for (final s in songs) s.name], ['可播']);
    });

    test('跨批去重, 且某一批没新歌就提前收工(不继续白拉)', () async {
      final fm = FakeFm([
        [1, 2],
        [2, 1], // 服务端开始回重复
        [7, 8], // 不该再请求到这一批
      ]);
      final songs = await loadFmBatches(fm.call, batches: 5);
      expect([for (final s in songs) s.id.toInt()], [1, 2]);
      expect(fm.calls, 2, reason: '第二批没有新歌 ⇒ 停止');
    });

    test('seen 里的曲目不会再进来(续播时挡住重复)', () async {
      final fm = FakeFm([
        [1, 2],
      ]);
      final songs = await loadFmBatches(
        fm.call,
        batches: 1,
        seen: {BigInt.one},
      );
      expect([for (final s in songs) s.id.toInt()], [2]);
    });
  });

  group('GuideQueueAdvance: 私人FM', () {
    test('段内顺序前进, 走到段尾续一批再继续(不回到第一首)', () async {
      final fm = FakeFm([
        [3, 4],
      ]);
      final advance = GuideQueueAdvance(
        fetchFm: fm.call,
        fetchHeart: (_) async => const [],
      );
      final queue = PlayQueue<rust.SongDto>()
        ..setAll([
          fakeSong(id: 1, name: 'FM1'),
          fakeSong(id: 2, name: 'FM2'),
        ], startAt: 0)
        ..mode = PlayMode.shuffle;

      expect((await advance.next(queue, QueueGuide.fm))?.id.toInt(), 2);
      // 段尾: 续一批(假服务只给 3,4) → 接着播 3, 队列从 2 首变 4 首
      expect((await advance.next(queue, QueueGuide.fm))?.id.toInt(), 3);
      expect(queue.items.length, 4);
      expect(fm.calls, 1);
      expect((await advance.next(queue, QueueGuide.fm))?.id.toInt(), 4);
      // 再往后没货了 ⇒ null(停在最后一首), 不会绕回第一首
      expect(await advance.next(queue, QueueGuide.fm), isNull);
    });

    test('随机播放也不打乱 FM 的顺序(引导态不看 PlayMode)', () async {
      final advance = GuideQueueAdvance(
        fetchFm: () async => const [],
        fetchHeart: (_) async => const [],
      );
      final queue = PlayQueue<rust.SongDto>()
        ..setAll([
          fakeSong(id: 1, name: 'a'),
          fakeSong(id: 2, name: 'b'),
          fakeSong(id: 3, name: 'c'),
        ])
        ..mode = PlayMode.shuffle;
      expect((await advance.next(queue, QueueGuide.fm))?.name, 'b');
      expect((await advance.next(queue, QueueGuide.fm))?.name, 'c');
      expect(queue.mode, PlayMode.shuffle, reason: '引导态不偷偷改 mode');
    });

    test('取数抛错: 返回 null, 不打断当前播放', () async {
      final advance = GuideQueueAdvance(
        fetchFm: () async => throw Exception('network'),
        fetchHeart: (_) async => const [],
      );
      final queue = PlayQueue<rust.SongDto>()
        ..setAll([fakeSong(id: 1, name: 'a')]);
      expect(await advance.next(queue, QueueGuide.fm), isNull);
      expect(queue.current?.name, 'a');
    });

    test('续到的歌已在最近窗口里: 不入队也不播', () async {
      final advance = GuideQueueAdvance(
        fetchFm: () async => [
          fakeSong(id: 1, name: 'a'),
          fakeSong(id: 2, name: 'b'),
        ],
        fetchHeart: (_) async => const [],
      );
      // 已经播到段尾(下标在最后一首)才会去续一批
      final queue = PlayQueue<rust.SongDto>()
        ..setAll([
          fakeSong(id: 1, name: 'a'),
          fakeSong(id: 2, name: 'b'),
        ], startAt: 1);
      expect(await advance.next(queue, QueueGuide.fm), isNull);
      expect(queue.items.length, 2);
    });
  });

  group('GuideQueueAdvance: 心动模式', () {
    test('段内顺序前进, 段尾用当前曲目当种子再取一批', () async {
      final seeds = <BigInt>[];
      final advance = GuideQueueAdvance(
        fetchFm: () async => const [],
        fetchHeart: (seed) async {
          seeds.add(seed.id);
          return [
            fakeSong(id: 11, name: '推荐11'),
            fakeSong(id: 12, name: '推荐12'),
          ];
        },
      );
      final queue = PlayQueue<rust.SongDto>()
        ..setAll([fakeSong(id: 1, name: '种子'), fakeSong(id: 2, name: '推荐')])
        ..mode = PlayMode.repeatOne;

      expect((await advance.next(queue, QueueGuide.heart))?.id.toInt(), 2);
      // 段尾: 用当前曲目(2)当种子续一批
      expect((await advance.next(queue, QueueGuide.heart))?.id.toInt(), 11);
      expect(seeds.map((e) => e.toInt()), [2]);
      expect(queue.items.length, 4);
      // 单曲循环不会把它钉成一首歌循环
      expect(queue.mode, PlayMode.repeatOne);
      expect((await advance.next(queue, QueueGuide.heart))?.id.toInt(), 12);
    });
  });

  group('GuideQueueAdvance: 普通播放', () {
    test('guide == none 时退回 PlayMode 语义(onEnded)', () async {
      final advance = GuideQueueAdvance(
        fetchFm: () async => const [],
        fetchHeart: (_) async => const [],
      );
      final queue = PlayQueue<rust.SongDto>()
        ..setAll([fakeSong(id: 1), fakeSong(id: 2)], startAt: 1)
        ..mode = PlayMode.repeatAll;
      expect(
        (await advance.next(queue, QueueGuide.none))?.id.toInt(),
        1,
        reason: '列表循环回到队首',
      );
    });
  });
}
