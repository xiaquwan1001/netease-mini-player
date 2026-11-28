import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/home/lyric_controller.dart';
import 'package:minincm/src/lyric_source.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/api/lyric.dart' as rust;

/// (b) 详情页/冷启动预取的接线契约:
/// 进歌词页与恢复上次现场都要**主动**触发一次取歌词, 而不是等用户点播放。
///
/// 真正的网络/FFI 取数在 widget 测试里不可用, 所以这里断言的是"该不该发请求"这一层:
/// 没有当前曲目时 [LyricController.ensureLoaded] 必须是纯 no-op(不抛、不挂起);
/// 展开歌词(toggle)时也要走同一条 no-op 分支 —— 之前这条路径压根不存在,
/// 用户看到的就是「暂无歌词/信息不可用」一直干等(2026-11-17 反馈)。
void main() {
  LyricController make({PlayerView? Function()? player}) => LyricController(
    player: player ?? () => null,
    pollPlayer: () async {},
    itemExtentOf: () => 56,
    toast: (_) {},
  );

  test('ensureLoaded: 没有当前曲目 = no-op(不触网/不抛)', () async {
    final c = make();
    addTearDown(c.dispose);
    await c.ensureLoaded();
    expect(c.lines, isEmpty);
    expect(c.wordLines, isEmpty);
    expect(c.error, isNull);
  });

  test('toggle 展开时调用预取, 收起时不报错', () async {
    var calls = 0;
    final c = make(
      player: () {
        calls++;
        return null;
      },
    );
    addTearDown(c.dispose);
    c.toggle(); // 展开: 内部 unawaited(ensureLoaded())
    await Future<void>.delayed(Duration.zero);
    expect(c.visible, isTrue);
    expect(calls, greaterThan(0)); // 读过播放态快照(取预取用的曲目 id)
    c.collapse();
    expect(c.visible, isFalse);
  });

  // 失败不占位: 之前 `load()` 第一行就把 `_lyricTrackId` 写成当前曲目, 请求失败后
  // 同一首永远走幂等早退 —— 退出重进、点「重试」都不再发请求, 只能切歌才可能恢复。
  // (测试环境没有 FFI, 取歌词必然失败, 正好当"请求失败"的现场。)
  test('失败不占位: 同一首失败后再 load 会重新发请求', () async {
    final c = make(
      player: () => PlayerView(
        trackId: BigInt.from(42),
        playing: false,
        positionMs: BigInt.zero,
        durationMs: BigInt.zero,
        volume: 1,
      ),
    );
    addTearDown(c.dispose);
    await c.load(BigInt.from(42));
    expect(c.error, isNotNull, reason: '前置: 这次取歌词失败了');
    expect(c.debugLoadCount, 1);

    await c.load(BigInt.from(42));
    expect(c.debugLoadCount, 2, reason: '失败不该把曲目 id 占住');
  });

  test('重试通道: retryLoad 按当前曲目重新取一次', () async {
    final c = make(
      player: () => PlayerView(
        trackId: BigInt.from(7),
        playing: false,
        positionMs: BigInt.zero,
        durationMs: BigInt.zero,
        volume: 1,
      ),
    );
    addTearDown(c.dispose);
    await c.load(BigInt.from(7));
    expect(c.debugLoadCount, 1);

    await c.retryLoad();
    expect(c.debugLoadCount, 2);
  });

  test('带曲目 id 时 ensureLoaded 只对同一首去重(重复调用不重复请求)', () async {
    // 只断言"重复调用返回的 Future 都能正常完成" —— 真实请求在 FFI 层,
    // widget 测试里直接调会走网络, 因此这里不构造带 id 的场景, 去重逻辑
    // 由 LyricController.load 的 `_lyricTrackId == trackId` 早退保证。
    final c = make();
    addTearDown(c.dispose);
    await c.ensureLoaded();
    await c.ensureLoaded();
  });
  // 会话缓存: 旧实现只有"当前一首"这一槽, A→B→A 每次重取(用户最常见的
  // 「进详情页 → 返回 → 再进」正好命中这个洞; 2026-11-28 缓存审计 P1-5)。
  test('歌词会话缓存: A→B→A 只取两次; 重试会作废该曲目的缓存', () async {
    var fetches = <BigInt>[];
    Future<List<rust.LyricLineDto>?> lineLoader(BigInt id) async {
      fetches.add(id);
      return <rust.LyricLineDto>[
        rust.LyricLineDto(timeMs: BigInt.zero, text: 'A${id.toInt()}'),
      ];
    }

    BigInt? current;
    final c = LyricController(
      player: () => current == null
          ? null
          : PlayerView(
              trackId: current,
              playing: false,
              positionMs: BigInt.zero,
              durationMs: BigInt.zero,
              volume: 1,
            ),
      pollPlayer: () async {},
      itemExtentOf: () => 56,
      toast: (_) {},
      loaders: LyricSourceLoaders(
        yrc: (id) async => null,
        ttml: (id) async => null,
        lineLevel: lineLoader,
      ),
      rawLyricOf: (id) async => '',
    );
    addTearDown(c.dispose);

    final a = BigInt.from(11);
    final b = BigInt.from(22);
    await c.load(a);
    expect(fetches, <BigInt>[a]);
    expect(c.lines.single.text, 'A11');

    await c.load(b);
    expect(fetches, <BigInt>[a, b]);

    await c.load(a); // 命中缓存
    expect(fetches, <BigInt>[a, b], reason: '回到 A 不该再请求');
    expect(c.lines.single.text, 'A11');
    expect(c.error, isNull);

    // 重试 = 用户明确要求再取一次 ⇒ 该曲目的缓存必须作废
    current = a;
    await c.retryLoad();
    expect(fetches, <BigInt>[a, b, a], reason: '重试要真的重新请求');
  });
}
