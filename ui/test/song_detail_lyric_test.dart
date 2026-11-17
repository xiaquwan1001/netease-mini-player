import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/lyric.dart';
import 'package:minincm/src/word_lyric_view.dart';

ParsedLyricLine _line(String text, {String? sub, int ms = 0}) =>
    ParsedLyricLine(timeMs: BigInt.from(ms), text: text, sub: sub);

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('TimedLyricView: 详情页行级歌词', () {
    final lines = [
      _line('第一句', sub: 'first line', ms: 0),
      _line('第二句', sub: 'second line', ms: 5000),
      _line('第三句', ms: 10000),
    ];

    testWidgets('长按/点击回调带行号, 选中行有高亮', (tester) async {
      final taps = <int>[];
      final longs = <int>[];
      await tester.pumpWidget(
        _host(
          TimedLyricView(
            lines: lines,
            activeIndex: 1,
            selected: const {2},
            onLineTap: taps.add,
            onLineLongPress: longs.add,
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('lyric-line-0')));
      await tester.longPress(find.byKey(const ValueKey('lyric-line-2')));
      expect(taps, [0]);
      expect(longs, [2]);

      // 选中行的容器带底色(多选的可见反馈)
      final box = tester.widget<Container>(
        find
            .descendant(
              of: find.byKey(const ValueKey('lyric-line-2')),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(box.decoration, isA<BoxDecoration>());
    });

    testWidgets('翻译开关: 关掉后 sub 文案不再渲染', (tester) async {
      await tester.pumpWidget(
        _host(
          TimedLyricView(lines: lines, activeIndex: 0, showTranslation: true),
        ),
      );
      expect(find.text('first line'), findsOneWidget);

      await tester.pumpWidget(
        _host(
          TimedLyricView(lines: lines, activeIndex: 0, showTranslation: false),
        ),
      );
      expect(find.text('first line'), findsNothing);
      // 主歌词始终在
      expect(find.text('第一句'), findsOneWidget);
    });

    testWidgets('300dp + 1.25 字号: 长行+翻译不溢出', (tester) async {
      tester.view.physicalSize = const Size(300, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
            child: Scaffold(
              body: TimedLyricView(
                lines: [
                  _line(
                    '一句很长很长很长的歌词用于小屏回归测试一句很长很长很长的歌词用于小屏回归测试',
                    sub: 'a very long translation line for the narrow screen regression',
                    ms: 0,
                  ),
                  _line('第二句', ms: 5000),
                ],
                activeIndex: 0,
                showTranslation: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('一句很长很长'), findsOneWidget);
    });

    testWidgets('高光行只略微增大字号, 两种行都居中(不再左右瞬移)', (tester) async {
      await tester.pumpWidget(
        _host(TimedLyricView(lines: lines, activeIndex: 0)),
      );

      final active = tester.widget<Text>(find.text('第一句'));
      final idle = tester.widget<Text>(find.text('第二句'));

      // 居中: 高亮行与普通行同一对齐口径(2026-11-17 用户反馈)
      expect(active.textAlign, TextAlign.center);
      expect(idle.textAlign, TextAlign.center);
      // 只 +1sp, 不再是 18 vs 15 那种整行重排
      expect(active.style?.fontSize, kTimedLyricActiveFontSize);
      expect(idle.style?.fontSize, kTimedLyricFontSize);
      expect(
        (active.style!.fontSize! - idle.style!.fontSize!).abs(),
        lessThanOrEqualTo(1.0),
      );
    });

    testWidgets('空列表显示空态', (tester) async {
      await tester.pumpWidget(
        _host(const TimedLyricView(lines: [], activeIndex: -1)),
      );
      expect(find.text('暂无歌词'), findsOneWidget);
    });
  });

  group('PlainLyricView: 纯文本歌词也能长按选择', () {
    testWidgets('长按回调带行号', (tester) async {
      final longs = <int>[];
      await tester.pumpWidget(
        _host(
          PlainLyricView(lines: const ['甲', '乙'], onLineLongPress: longs.add),
        ),
      );
      await tester.longPress(find.byKey(const ValueKey('plain-lyric-line-1')));
      expect(longs, [1]);
    });
  });

  group('WordLyricView: 逐字歌词', () {
    WordLyricLineData wline(int start, String text, {String? sub}) =>
        WordLyricLineData(
          startMs: start,
          endMs: start + 1000,
          words: [
            WordLyricWord(startMs: start, endMs: start + 1000, text: text),
          ],
          sub: sub,
        );

    testWidgets('翻译开关 + 长按选择', (tester) async {
      final longs = <int>[];
      await tester.pumpWidget(
        _host(
          WordLyricView(
            lines: [
              wline(0, '甲', sub: 'jia'),
              wline(2000, '乙', sub: 'yi'),
            ],
            positionMs: ValueNotifier<int>(0),
            onLineLongPress: longs.add,
            showTranslation: false,
          ),
        ),
      );
      expect(find.text('jia'), findsNothing);

      await tester.longPress(find.byKey(const ValueKey('word-lyric-line-1')));
      expect(longs, [1]);
    });

    testWidgets('署名行(作词/作曲)高亮时与静态行同一对齐口径: 都居中', (tester) async {
      // 高光行走 CustomPaint(KaraokePainter), 静态行走 RichText。两条路径
      // 曾经不一致: 只给 maxWidth 的 TextPainter 宽 = 文本自身宽, 段落按行宽
      // 居中后又由 paintOffset 反向量左移, 净效果是高光行画在 x=0(贴左)。
      // 真实 yrc 的署名行是 {"t":0,...} 元数据行(start == end 零时长),
      // 播放位置 0 时它就是当前行, 走的高光路径。
      final credit = WordLyricLineData(
        startMs: 0,
        endMs: 0,
        words: const [WordLyricWord(startMs: 0, endMs: 0, text: '作词 : 方文山')],
      );
      await tester.pumpWidget(
        _host(
          WordLyricView(
            lines: [credit, wline(5000, '第一句')],
            positionMs: ValueNotifier<int>(0),
            itemExtent: 56,
            padding: EdgeInsets.zero,
          ),
        ),
      );

      final activeRow = tester.getRect(
        find.byKey(const ValueKey('word-lyric-line-0')),
      );
      final idleRow = tester.getRect(
        find.byKey(const ValueKey('word-lyric-line-1')),
      );

      // 高光行: 从画笔实际裁切矩形(画布坐标)反推已唱文本的水平中心
      final canvasFinder = find.descendant(
        of: find.byKey(const ValueKey('word-lyric-line-0')),
        matching: find.byType(CustomPaint),
      );
      final canvas = tester.getRect(canvasFinder);
      final painter =
          tester.widget<CustomPaint>(canvasFinder).painter! as KaraokePainter;
      expect(painter.debugClipRects, isNotEmpty);
      final activeText = painter.debugClipRects.first.shift(canvas.topLeft);

      // 静态行: RichText 自身矩形(宽度 = 文本固有宽, 由 Column 居中)
      final idleText = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('word-lyric-line-1')),
          matching: find.byType(RichText),
        ),
      );

      // 两种行都相对自己的行居中, 且互相一致(不再一边居中一边贴左)
      expect(activeText.center.dx, closeTo(activeRow.center.dx, 1.0));
      expect(idleText.center.dx, closeTo(idleRow.center.dx, 1.0));
      expect(activeText.center.dx, closeTo(idleText.center.dx, 1.0));
    });
  });
}
