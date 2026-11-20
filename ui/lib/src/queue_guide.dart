/// 引导态(心动模式 / 私人FM)的「续播取料」。
///
/// 为什么单独一层: 这两个模式的下一首**不是** [PlayMode] 能算出来的。
/// - 私人FM 的 `/api/v1/radio/get` 实测**一次只回 2 首**(2026-11-19 用
///   `ncm-cli -- raw fm` 连打三次, 每次 2 首且互不相同) ⇒ 只播一批的话队列面板
///   里永远只有两首歌, 播到末尾就被 PlayMode 接管(用户反馈的现场)。
/// - 心动模式一批 30 首, 播完要拿当前曲目当种子再来一批。
///
/// 全部走**注入的取数函数** + 真 [PlayQueue], 所以能脱离 Rust 单测
/// (`ui/test/queue_guide_test.dart`)。
library;

import 'queue.dart';
import 'rust/api_all.dart' as rust;

/// 私人FM 一次"入队"要连取几批。
///
/// 接口一次只回 2 首 ⇒ 只取一批 = 队列面板里只有两首(用户反馈)。
/// 取 3 批 = 6 首起步; 再多就是开一次 FM 打一串请求, 不值。
const int kFmBatchesPerFill = 3;

/// 只保留**可播且 id 未见过**的曲目(顺序不变); [seen] 就地更新, 调用方据此防重。
///
/// 不可播(无版权/VIP 且取不到链)的曲目直接不入队: 入队再被 `playSong` 跳过会
/// 让队列面板显示一堆点了没反应的歌。
List<rust.SongDto> filterFreshSongs(
  Iterable<rust.SongDto> songs,
  Set<BigInt> seen,
) {
  final fresh = <rust.SongDto>[];
  for (final song in songs) {
    if (!song.playable) continue;
    if (!seen.add(song.id)) continue;
    fresh.add(song);
  }
  return fresh;
}

/// 连取 [batches] 批 FM 曲目并去重。
///
/// 某一批没有新歌就提前收工: 服务端开始回重复时不必继续白拉。
Future<List<rust.SongDto>> loadFmBatches(
  Future<List<rust.SongDto>> Function() fetch, {
  int batches = kFmBatchesPerFill,
  Set<BigInt>? seen,
}) async {
  final known = seen ?? <BigInt>{};
  final fresh = <rust.SongDto>[];
  for (var i = 0; i < batches; i++) {
    final got = filterFreshSongs(await fetch(), known);
    if (got.isEmpty) break;
    fresh.addAll(got);
  }
  return fresh;
}

/// 引导态的"下一首/续一批"决策器。
///
/// 语义(与用户口径一致):
/// - 引导态下**顺序**走队列, 不看 [PlayMode](随机/单曲循环不许接管);
/// - 走到这一段队列的末尾就向 provider 续一批, 追加到队尾后继续播;
/// - 续不到就停在这一首(null), 不打断正在播的歌。
class GuideQueueAdvance {
  GuideQueueAdvance({
    required this.fetchFm,
    required this.fetchHeart,
    this.fmBatches = 1,
  });

  /// 私人FM 取一批原始曲目(生产: `rust.personalFm(limit: 30)`, 服务端只给 2 首)。
  final Future<List<rust.SongDto>> Function() fetchFm;

  /// 心动模式以 [seed] 为种子取一批(生产: `rust.heartModeSongs`; playlistId 由
  /// 调用方闭合注入, 这里是"当前歌单"的页面态)。
  final Future<List<rust.SongDto>> Function(rust.SongDto seed) fetchHeart;

  /// 续一批时连打几次 FM 接口(见 [kFmBatchesPerFill])。
  final int fmBatches;

  /// 「已听过」只看最近这么多首。
  ///
  /// FM 是无限流: 拿整个会话的历史去重, 跑几个小时后会一直"全部重复 ⇒ 取不到新歌";
  /// 最近 60 首足够挡住「同一首连着来两遍」, 又不会把老歌永久拉黑。
  static const int kRecentWindow = 60;

  /// 顺序前进一首; 队列末尾就续一批再前进。返回 null = 没有更多。
  ///
  /// [queue] 会被就地修改(追加新曲目 + 移动下标), 调用方负责通知 UI。
  Future<rust.SongDto?> next(
    PlayQueue<rust.SongDto> queue,
    QueueGuide guide,
  ) async {
    if (guide == QueueGuide.none) return queue.onEnded();
    final forward = queue.advanceSequential();
    if (forward != null) return forward;
    final seed = queue.current;
    final seen = _recentIds(queue);
    final List<rust.SongDto> fresh;
    try {
      if (guide == QueueGuide.fm) {
        fresh = await loadFmBatches(fetchFm, batches: fmBatches, seen: seen);
      } else {
        if (seed == null) return null;
        fresh = filterFreshSongs(await fetchHeart(seed), seen);
      }
    } catch (_) {
      // 取数失败就停在这一首(与"播完一首取不到链"同口径), 下一次手动切还能再试
      return null;
    }
    if (fresh.isEmpty) return null;
    for (final song in fresh) {
      queue.append(song);
    }
    return queue.advanceSequential();
  }

  Set<BigInt> _recentIds(PlayQueue<rust.SongDto> queue) {
    final items = queue.items;
    final start = items.length > kRecentWindow
        ? items.length - kRecentWindow
        : 0;
    return {for (final song in items.skip(start)) song.id};
  }
}
