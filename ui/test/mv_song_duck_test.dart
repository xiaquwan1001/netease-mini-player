import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/mv_page.dart';
import 'package:minincm/src/mv_playback.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

/// U-04(2026-11-18): 播 MV 时歌曲必须让路(暂停), 且 MV 结束后**不自动恢复**,
/// 返回本页给一次"要接着听点播放条"的提示。
///
/// 这里覆盖的是 Dart 侧的决策与接线(纯函数 + 注入假实现, 不触网络/平台通道);
/// 真正的听感(是否只剩 MV 声)只能在真机上确认, 见 .pi/plans/mv-audio-focus-2026-11-18.md。

rust.MvDetailDto _detail() => rust.MvDetailDto(
  id: BigInt.from(5436712),
  name: '主角',
  artistName: '王菲',
  durationMs: BigInt.from(284000),
  playCount: BigInt.from(377308),
  publishTime: '2026-05-07',
  coverUrl: null,
  maxBr: 0,
  brs: Uint32List.fromList(const []),
  desc: null,
);

rust.MvUrlDto _url() => rust.MvUrlDto(
  url: 'http://vod.example.com/a.mp4?wsSecret=x',
  r: 480,
  size: BigInt.from(31157772),
);

/// 假歌曲侧: 记录调用顺序, 并把 MV 侧的 play 也写进同一条日志(用于断言先后)
class _RecordingGate extends MvSongGate {
  _RecordingGate({this.playing = true, required this.log});

  bool playing;
  final List<String> log;

  @override
  Future<bool> isPlaying() async {
    log.add('song.isPlaying');
    return playing;
  }

  @override
  Future<void> pause() async {
    log.add('song.pause');
    playing = false;
  }

  @override
  Future<void> resume() async {
    log.add('song.resume');
    playing = true;
  }
}

class _RecordingPlayback extends MvPlayback {
  _RecordingPlayback({required this.gate, required this.log, this.fail = false})
    : super(songGate: gate);

  final _RecordingGate gate;
  final List<String> log;
  final bool fail;

  @override
  bool get supportsInlinePlayback => true;

  @override
  Future<void> play(String url, String title) async {
    log.add('mv.play');
    if (fail) throw Exception('channel boom');
  }
}

Future<void> _pumpMv(WidgetTester tester, MvPlayback playback) async {
  await tester.pumpWidget(
    MaterialApp(
      home: MvPage(
        mvId: BigInt.from(5436712),
        name: '主角',
        playback: playback,
        loadDetail: (_) async => _detail(),
        loadUrl: (_, r) async => _url(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 平台只会发合法序列: resumed → inactive → hidden → paused, 再反向回来。
/// MV 是独立 Activity, 打开/返回在 Flutter 侧就是这一组跳变。
Future<void> _leaveAndReturn(WidgetTester tester) async {
  for (final s in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
  for (final s in const [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  group('纯逻辑: 起播决策 / 返回策略', () {
    test('歌曲在播才暂停', () {
      expect(mvDuckPlan(songPlaying: true), MvSongDuckPlan.pause);
      expect(mvDuckPlan(songPlaying: false), MvSongDuckPlan.none);
    });

    test('没暂停过歌曲 ⇒ 返回后什么都不做', () {
      expect(mvReturnPlan(songWasDucked: false), MvReturnPlan.nothing);
    });

    test('默认口径: 暂停过也不自动恢复, 只提示手动续播', () {
      expect(mvReturnPlan(songWasDucked: true), MvReturnPlan.hintManualResume);
    });

    test('显式打开 autoResume 才会自动恢复(策略开关可测)', () {
      expect(
        mvReturnPlan(songWasDucked: true, autoResumeEnabled: true),
        MvReturnPlan.autoResume,
      );
    });
  });

  testWidgets('点播放: 先暂停歌曲再起 MV(顺序 + 只这一次)', (tester) async {
    final log = <String>[];
    final gate = _RecordingGate(log: log);
    await _pumpMv(tester, _RecordingPlayback(gate: gate, log: log));

    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();

    expect(log, ['song.isPlaying', 'song.pause', 'mv.play']);
    expect(find.textContaining('播放失败'), findsNothing);
  });

  testWidgets('歌曲本来没在播: 不暂停, 也不提示', (tester) async {
    final log = <String>[];
    final gate = _RecordingGate(playing: false, log: log);
    await _pumpMv(tester, _RecordingPlayback(gate: gate, log: log));

    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(log, ['song.isPlaying', 'mv.play']);

    await _leaveAndReturn(tester);
    expect(find.textContaining('歌曲已暂停'), findsNothing);
    expect(log.contains('song.resume'), isFalse);
  });

  testWidgets('从 MV 返回: 不自动恢复歌曲, 给一次手动续播提示', (tester) async {
    final log = <String>[];
    final gate = _RecordingGate(log: log);
    await _pumpMv(tester, _RecordingPlayback(gate: gate, log: log));

    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(log, ['song.isPlaying', 'song.pause', 'mv.play']);

    await _leaveAndReturn(tester);

    expect(find.textContaining('歌曲已暂停'), findsOneWidget);
    expect(log.contains('song.resume'), isFalse);

    // 只提示一次: 再进出一次后台不该重复弹
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    await _leaveAndReturn(tester);
    expect(find.textContaining('歌曲已暂停'), findsNothing);
  });

  testWidgets('MV 起播失败: 立刻恢复歌曲并给出错误文案', (tester) async {
    final log = <String>[];
    final gate = _RecordingGate(log: log);
    await _pumpMv(tester, _RecordingPlayback(gate: gate, log: log, fail: true));

    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();

    expect(log, ['song.isPlaying', 'song.pause', 'mv.play', 'song.resume']);
    expect(find.textContaining('播放失败'), findsOneWidget);
    expect(find.textContaining('channel boom'), findsOneWidget);

    // 回滚过就不再给"手动续播"提示(否则等于让用户点两次)
    await _leaveAndReturn(tester);
    expect(find.textContaining('歌曲已暂停'), findsNothing);
  });
}
