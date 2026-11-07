import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/word_lyric_view.dart';

WordLyricLineData _line(
  int start,
  int end,
  List<(int, int, String)> words, {
  String? sub,
}) =>
    WordLyricLineData(
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
  List<WordLyricLineData>? lines,
  ScrollController? controller,
  double textScale = 1.0,
}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SizedBox(
          width: 300,
          child: WordLyricView(
            lines: lines ?? _lines,
            positionMs: pos,
            controller: controller,
          ),
        ),
      ),
    );

/// 收集树里所有逐字行 TextSpan(带词文本), 按文本查颜色。
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

  testWidgets('逐字高亮随位置推进(3 个时间点)', (tester) async {
    final pos = ValueNotifier<int>(1200);
    await tester.pumpWidget(_host(pos));
    await tester.pumpAndSettle();

    // t=1200: '你'当前(primary), '陪'未唱(灰)
    var styles = _spanStyles(tester);
    expect(styles['你']!.color, isNot(styles['陪']!.color));
    final currentColor = styles['你']!.color;

    // t=2200: '陪'从灰变 primary —— 高亮随位置推进
    pos.value = 2200;
    await tester.pumpAndSettle();
    styles = _spanStyles(tester);
    expect(styles['陪']!.color, currentColor);

    // t=5200: 切到第 1 行, 第 0 行退回静态灰
    pos.value = 5200;
    await tester.pumpAndSettle();
    styles = _spanStyles(tester);
    // ignore: avoid_print
    expect(styles['蝉夏 ']!.color, currentColor);
    // 旧行已回落为静态整行(灰色)
    expect(styles['你陪我']!.color, isNot(currentColor));

    // t=7500: 第 2 行活动, 行级翻译可见
    pos.value = 7500;
    await tester.pumpAndSettle();
    expect(find.text('goodbye'), findsOneWidget);
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
