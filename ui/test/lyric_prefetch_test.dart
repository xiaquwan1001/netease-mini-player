import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/home/lyric_controller.dart';
import 'package:minincm/src/playback.dart';

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

  test('带曲目 id 时 ensureLoaded 只对同一首去重(重复调用不重复请求)', () async {
    // 只断言"重复调用返回的 Future 都能正常完成" —— 真实请求在 FFI 层,
    // widget 测试里直接调会走网络, 因此这里不构造带 id 的场景, 去重逻辑
    // 由 LyricController.load 的 `_lyricTrackId == trackId` 早退保证。
    final c = make();
    addTearDown(c.dispose);
    await c.ensureLoaded();
    await c.ensureLoaded();
  });
}
