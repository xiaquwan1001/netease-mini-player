import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/word_lyric_view.dart';

WordLyricLineData _line(
  int start,
  int end,
  List<(int, int, String)> words, {
  String? sub,
}) => WordLyricLineData(
  startMs: start,
  endMs: end,
  words: [
    for (final (s, e, t) in words) WordLyricWord(startMs: s, endMs: e, text: t),
  ],
  sub: sub,
);

final _lines = [
  _line(1000, 3000, [(1000, 1500, '你'), (1500, 2000, '陪'), (2000, 3000, '我')]),
  _line(4000, 6000, [(4000, 5000, '步入'), (5000, 6000, '蝉夏 ')]),
  _line(7000, 9000, [(7000, 9000, '再见')], sub: 'goodbye'),
];

Widget _host(
  ValueListenable<int> pos, {
  ValueListenable<bool>? playing,
  List<WordLyricLineData>? lines,
  ScrollController? controller,
  double textScale = 1.0,
  bool reduceMotion = false,
}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale),
      disableAnimations: reduceMotion,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: SizedBox(
      width: 300,
      child: WordLyricView(
        lines: lines ?? _lines,
        positionMs: pos,
        playing: playing,
        controller: controller,
      ),
    ),
  ),
);

/// 收集树里所有静态行 RichText(带词文本), 按文本查颜色。
/// 活动行不再由 RichText 渲染(改成 CustomPaint), 所以这里只剩静态行。
Map<String, TextStyle> _spanStyles(WidgetTester tester) {
  final out = <String, TextStyle>{};
  for (final rt in tester.widgetList<RichText>(find.byType(RichText))) {
    final span = rt.text as TextSpan;
    if (span.children == null) {
      if (span.text != null) out[span.text!] = span.style!;
      continue;
    }
    for (final child in span.children!.whereType<TextSpan>()) {
      if (child.text != null) out[child.text!] = child.style!;
    }
  }
  return out;
}

/// 活动行的画笔(裁切结果通过 @visibleForTesting 暴露)。
KaraokePainter _activePainter(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find.descendant(
      of: find.byType(KaraokeLine),
      matching: find.byType(CustomPaint),
    ),
  );
  return paint.painter! as KaraokePainter;
}

KaraokeLineState _activeState(WidgetTester tester) =>
    tester.state<KaraokeLineState>(find.byType(KaraokeLine));

void main() {
  test('wordLineIndexAt 定位当前行', () {
    expect(wordLineIndexAt(_lines, 0), -1);
    expect(wordLineIndexAt(_lines, 999), -1);
    expect(wordLineIndexAt(_lines, 1000), 0);
    expect(wordLineIndexAt(_lines, 3500), 0);
    expect(wordLineIndexAt(_lines, 4000), 1);
    expect(wordLineIndexAt(_lines, 99999), 2);
  });

  test('wordStylesAt: 已唱/当前/未唱 + 词内进度', () {
    // t=1750: '你'已唱, '陪'是当前词, '我'未唱
    final a = wordStylesAt(_lines[0], 1750);
    expect(a[0].state, WordHighlightState.sung);
    expect(a[1].state, WordHighlightState.current);
    expect(a[1].progress, closeTo(0.5, 1e-9));
    expect(a[2].state, WordHighlightState.upcoming);

    // t=2200: '我' 当前, 进度 0.2
    final b = wordStylesAt(_lines[0], 2200);
    expect(b[0].state, WordHighlightState.sung);
    expect(b[1].state, WordHighlightState.sung);
    expect(b[2].state, WordHighlightState.current);
    expect(b[2].progress, closeTo(0.2, 1e-9));

    // 零时长词: 到点即视为已唱
    const zero = WordLyricLineData(
      startMs: 0,
      endMs: 100,
      words: [WordLyricWord(startMs: 50, endMs: 50, text: 'x')],
    );
    expect(wordStylesAt(zero, 50).single.state, WordHighlightState.sung);

    // 退化整行(词表空)
    const whole = WordLyricLineData(startMs: 0, endMs: 100, words: []);
    expect(wordStylesAt(whole, 50).single.state, WordHighlightState.current);
    expect(wordStylesAt(whole, 200).single.state, WordHighlightState.upcoming);
  });

  testWidgets('空数据 → 空态文案', (tester) async {
    final pos = ValueNotifier<int>(0);
    await tester.pumpWidget(_host(pos, lines: const []));
    expect(find.text('暂无歌词'), findsOneWidget);
  });

  testWidgets('逐字裁切随位置推进(3 个时间点)', (tester) async {
    final pos = ValueNotifier<int>(1200);
    await tester.pumpWidget(_host(pos));
    await tester.pumpAndSettle();

    // t=1200: '你'当前(progress 0.4), 顶层裁切只亮 40% 词宽
    var painter = _activePainter(tester);
    var rects = painter.debugClipRects;
    expect(rects, isNotEmpty);
    final firstWidth = painter.debugLeadingClipWidth;
    expect(firstWidth, greaterThan(0));
    final wordWidth = firstWidth / 0.4;
    expect(firstWidth, lessThan(wordWidth));

    // t=1500: '你'唱完, 裁切推进到整词宽
    pos.value = 1500;
    await tester.pumpAndSettle();
    painter = _activePainter(tester);
    expect(painter.debugLeadingClipWidth, closeTo(wordWidth, 0.5));

    // t=2200: '你陪'已唱合并 + '我'亮 20%
    pos.value = 2200;
    await tester.pumpAndSettle();
    painter = _activePainter(tester);
    expect(painter.debugClipRects.length, 1, reason: '已唱与当前词应合并成一段');
    expect(painter.debugLeadingClipWidth, greaterThan(wordWidth));

    // t=5200: 切到第 1 行(活动行换成 KaraokeLine), 第 0 行退回静态灰
    final primary = Theme.of(
      tester.element(find.byKey(const ValueKey('word-lyric-line-0'))),
    ).colorScheme.primary;
    pos.value = 5200;
    await tester.pumpAndSettle();
    painter = _activePainter(tester);
    expect(painter.sungColor, primary);
    expect(painter.line.startMs, 4000);
    final staticStyles = _spanStyles(tester);
    expect(staticStyles['你陪我']!.color, isNot(primary));

    // t=7500: 第 2 行活动, 行级翻译可见
    pos.value = 7500;
    await tester.pumpAndSettle();
    expect(find.text('goodbye'), findsOneWidget);
    expect(_activePainter(tester).line.startMs, 7000);
  });

  testWidgets('playing=true: 本地插值, 裁切宽逐帧单调递增', (tester) async {
    final pos = ValueNotifier<int>(1200);
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);
    await tester.pumpWidget(_host(pos, playing: playing));
    await tester.pump();

    final state = _activeState(tester);
    expect(state.debugInterpolating, isTrue);

    // 3 帧: 父级位置不变, 只靠本地插值推进
    final widths = <double>[];
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(_activePainter(tester).debugLeadingClipWidth);
    }
    expect(widths[1], greaterThan(widths[0]), reason: '插件插值: 每帧都要更宽');
    expect(widths[2], greaterThan(widths[1]));
  });

  testWidgets('playing=false: 不插值, 3 帧内裁切宽不变', (tester) async {
    final pos = ValueNotifier<int>(1200);
    final playing = ValueNotifier<bool>(false);
    addTearDown(playing.dispose);
    await tester.pumpWidget(_host(pos, playing: playing));
    await tester.pump();

    expect(_activeState(tester).debugInterpolating, isFalse);
    final widths = <double>[];
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      widths.add(_activePainter(tester).debugLeadingClipWidth);
    }
    expect(widths[0], widths[1]);
    expect(widths[1], widths[2]);
  });

  testWidgets('reduce motion: 不插值也不排帧(只按 state 跳变)', (tester) async {
    final pos = ValueNotifier<int>(1200);
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);
    await tester.pumpWidget(_host(pos, playing: playing, reduceMotion: true));
    await tester.pump();

    final state = _activeState(tester);
    expect(
      state.debugInterpolating,
      isFalse,
      reason: 'reduce motion 下不能起 Ticker',
    );
    final width = _activePainter(tester).debugLeadingClipWidth;
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(_activePainter(tester).debugLeadingClipWidth, width);
    }
    expect(state.debugInterpolating, isFalse);

    // 但位置真的变了还是要跟着跳(不是完全冻住)
    pos.value = 1400;
    await tester.pump();
    expect(_activePainter(tester).debugLeadingClipWidth, greaterThan(width));
  });

  testWidgets('播放中暂停: Ticker 停下, 位置冻结', (tester) async {
    final pos = ValueNotifier<int>(1200);
    final playing = ValueNotifier<bool>(true);
    addTearDown(playing.dispose);
    await tester.pumpWidget(_host(pos, playing: playing));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 16));

    playing.value = false;
    await tester.pump();
    expect(_activeState(tester).debugInterpolating, isFalse);
    final frozen = _activeState(tester).debugPositionMs;
    await tester.pump(const Duration(milliseconds: 32));
    expect(_activeState(tester).debugPositionMs, frozen);
  });

  testWidgets('活动行不再放大字号(key 保留, 主文本走 Semantics)', (tester) async {
    final pos = ValueNotifier<int>(1200);
    await tester.pumpWidget(_host(pos));
    await tester.pumpAndSettle();

    // 主文本由 CustomPaint 绘制, 语义标签补回整行文本
    expect(find.bySemanticsLabel('你陪我'), findsOneWidget);
    // 活动行里没有 RichText(避免重排/抖动)
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('word-lyric-line-0')),
        matching: find.byType(RichText),
      ),
      findsNothing,
    );
    expect(karaokeActiveTextStyle.fontSize, 15);
    expect(_activePainter(tester).style.fontSize, 15);
  });

  testWidgets('行级自动滚动到当前行', (tester) async {
    final controller = ScrollController();
    final pos = ValueNotifier<int>(0);
    await tester.pumpWidget(_host(pos, controller: controller));
    await tester.pumpAndSettle();
    pos.value = 7500; // 第 2 行
    await tester.pumpAndSettle();
    // 视口 600 高, 3 行 × 56 = 168 < 600: maxScrollExtent=0, 已居中
    expect(controller.offset, 0.0);
  });

  testWidgets('词文本含空格/标点不崩, 300dp 视口不溢出', (tester) async {
    final pos = ValueNotifier<int>(1200);
    final lines = [
      _line(0, 2000, [
        (0, 500, 'Hello, '),
        (500, 1000, 'world! '),
        (1000, 2000, '……(feat. 某人) '),
      ]),
    ];
    await tester.pumpWidget(_host(pos, lines: lines));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('1.25 大字号 + 300dp 不溢出', (tester) async {
    final pos = ValueNotifier<int>(7500);
    await tester.pumpWidget(_host(pos, textScale: 1.25));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('超长行被 ellipsis 截断, 后面的词不产生裁切矩形', (tester) async {
    final pos = ValueNotifier<int>(500);
    final lines = [
      _line(0, 4000, [
        (0, 1000, '一句非常非常非常长的歌词用来撑满整行并溢出容器宽度'),
        (1000, 2000, '后面的词根本放不下'),
      ]),
    ];
    await tester.pumpWidget(_host(pos, lines: lines));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final painter = _activePainter(tester);
    expect(painter.debugClipRects.every((r) => r.right <= 300.5), isTrue);
  });

  testWidgets('组件销毁后位置 notifier 更新无异常(无残留监听)', (tester) async {
    final pos = ValueNotifier<int>(0);
    await tester.pumpWidget(_host(pos));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    pos.value = 1200; // 监听器已随 dispose 移除, 不应抛错
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
