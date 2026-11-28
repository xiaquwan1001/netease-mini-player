// 回归: 不可见子树必须真静音 ticker(审计 audit-flutter-perf-20261128 §2)。
//
// Flutter 的 Offstage **不**静音 ticker(SDK: "Animations continue to run in
// offstage children")。DetailFaces 之前把歌词面/封面面只包在 Offstage 里, 于是
// 用户看封面时逐字歌词的 60fps 插值照旧排帧。这里给两面各套一层 TickerMode,
// 用 hasScheduledFrame 钉住: 背面完全不可见后就不再排帧。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail_faces.dart';

final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIA'
  'X8jx0gAAAABJRU5ErkJggg==',
);

/// 一直跑的动画替身(模拟逐字歌词的 KaraokeLine 插值): 在 TickerMode 关闭的
/// 子树里它的 ticker 会被静音, 从而不再排帧。
class _SpinningLyrics extends StatefulWidget {
  const _SpinningLyrics();

  @override
  State<_SpinningLyrics> createState() => _SpinningLyricsState();
}

class _SpinningLyricsState extends State<_SpinningLyrics>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: _controller, child: const SizedBox.expand());
}

void main() {
  testWidgets('看封面面时, 歌词面的 ticker 被静音(不再排帧)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DetailFaces(
            trackId: BigInt.one,
            coverUrl: null,
            lyrics: const _SpinningLyrics(),
            // 首帧就在封面面 ⇒ 歌词面 Offstage + TickerMode(enabled: false)。
            initialFace: DetailFace.cover,
            fetchImage: (url) async => _png1x1,
          ),
        ),
      ),
    );
    // 让封面大图的异步解码与淡入走完(不 pumpAndSettle: 歌词 ticker 若没被静音
    // 会永远不静止, 那正是本用例要区分的东西)。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '歌词面不可见时逐字行 ticker 必须真停, 不能后台排帧',
    );
  });

  testWidgets('切回歌词面后, 歌词 ticker 恢复排帧', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DetailFaces(
            trackId: BigInt.one,
            coverUrl: null,
            lyrics: const _SpinningLyrics(),
            initialFace: DetailFace.cover,
            fetchImage: (url) async => _png1x1,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 轻点封面面 → 切回歌词面(交叉淡入 200ms 期间两面都在场)。
    await tester.tap(find.byKey(const ValueKey('detail-cover-face')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '歌词面可见后 ticker 应恢复, 否则歌词不再滚动/插值',
    );
  });
}
