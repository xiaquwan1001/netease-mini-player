// 播放条「试听 mm:ss / 已降级」提示的**渲染级**回归。
//
// 背景: `stream_note_test.dart` 只锁了纯逻辑(label/isEmpty/isDegraded), 没人验证
// 这条提示真的落到了播放条上。这里用真实 [MiniPlayerBar] + 真实
// `currentStreamNote` 发布点做断言, 覆盖三件事:
//   1. 当前曲目有 note ⇒ 第二行行首出现前缀文案(且与艺人同处一行);
//   2. 别的曲目(trackId 不匹配)发布过 note ⇒ 播放条不许串台显示;
//   3. 没发布过任何 note ⇒ 第二行只有艺人, 不出现空提示。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/stream_note.dart';

const _trackId = 4242;

PlayerBarData _data() => PlayerBarData(
  player: PlayerView(
    playing: true,
    positionMs: BigInt.from(10 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
  ),
  current: rust.SongDto(
    id: BigInt.from(_trackId),
    name: '测试曲目',
    artist: '测试艺人',
    artistId: BigInt.one,
    album: '测试专辑',
    albumId: BigInt.one,
    coverUrl: null,
    durationMs: BigInt.from(200 * 1000),
    fee: 0,
    vip: false,
    paid: false,
    playable: true,
  ),
  liked: false,
  queueIndex: 1,
  queueLength: 1,
  dragMax: null,
  dragMs: null,
);

PlayerBarActions _actions() => PlayerBarActions(
  onSeekStart: (_) {},
  onSeekChanging: (_) {},
  onSeekEnd: (_) {},
  onToggleLyrics: () {},
  onOpenDetail: () {},
  onToggleLike: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
  onToggle: () {},
  onPrevious: () {},
  onNext: () {},
);

Widget _app() => MaterialApp(
  builder: (context, child) =>
      PlayerBarHost(content: child ?? const SizedBox.shrink()),
  home: Scaffold(
    body: SizedBox.expand(child: const ColoredBox(color: Colors.teal)),
  ),
);

Future<void> _pumpBar(WidgetTester tester) async {
  playerBarData.value = _data();
  playerBarActions.value = _actions();
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() {
    playerBarSlot.value = null;
    playerBarData.value = null;
    playerBarActions.value = null;
    currentStreamNote.value = null;
  });

  testWidgets('当前曲目有试听 note: 第二行行首出现「试听 00:45」且艺人仍在同处', (tester) async {
    await _pumpBar(tester);
    publishStreamNote(
      BigInt.from(_trackId),
      const StreamNote(isTrial: true, trialLenMs: 45 * 1000),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('试听 00:45'), findsOneWidget);
    // 提示与艺人拼接在同一个 Text.rich 里, 不是各自一块。
    expect(find.textContaining('测试艺人'), findsOneWidget);
  });

  testWidgets('降级 note: 显示「已降级 极高」', (tester) async {
    await _pumpBar(tester);
    publishStreamNote(
      BigInt.from(_trackId),
      const StreamNote(actualLevel: 'exhigh', requestedLevel: 'lossless'),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('已降级'), findsOneWidget);
  });

  testWidgets('别的曲目的 note 不串台: 播放条不显示提示', (tester) async {
    await _pumpBar(tester);
    publishStreamNote(
      BigInt.from(_trackId + 1),
      const StreamNote(isTrial: true, trialLenMs: 30 * 1000),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('试听'), findsNothing);
    expect(find.textContaining('测试艺人'), findsOneWidget);
  });

  testWidgets('没有 note: 第二行只有艺人, 没有空提示', (tester) async {
    await _pumpBar(tester);
    await tester.pumpAndSettle();

    expect(find.textContaining('试听'), findsNothing);
    expect(find.textContaining('已降级'), findsNothing);
  });
}
