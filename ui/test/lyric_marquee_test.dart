// 超长歌词行的横向滚动(2026-11-17 用户反馈: 长句一直被省略号截断, 看不到后半句).
//
// 口径:
// - **当前(高亮)行**超宽 => 横向自动滚动, 复用 marquee_text.dart 的同一台跑马灯内核;
// - **非当前行**保持单行 ellipsis(不能让整页歌词都在动);
// - 只有播放中才滚(TickerMode 静音 ticker), 暂停/静态预览零排帧;
// - 逐字(karaoke)当前行滚动时不能先被 ellipsis 截断再平移, 必须按全文宽排版;
// - 300dp + 1.25 字号不溢出.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/lyric.dart';
import 'package:minincm/src/marquee_text.dart';
import 'package:minincm/src/word_lyric_view.dart';

const _long = '一句非常非常非常长的歌词用来撑满整行并溢出容器宽度再溢出一次才能确认滚动';
const _short = '第二句';

ParsedLyricLine _line(String text, {String? sub, int ms = 0}) =>
    ParsedLyricLine(timeMs: BigInt.from(ms), text: text, sub: sub);

Widget _host(Widget child, {double width = 300, double textScale = 1.0}) =>
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

/// 某一行的子树里是否有跑马灯视口.
Finder _scrollIn(String rowKey) => find.descendant(
  of: find.byKey(ValueKey(rowKey)),
  matching: find.byType(MarqueeScroll),
);

/// 跑马灯当前的横向位移(没有位移组件时返回 null).
double? _offsetX(WidgetTester tester, Finder scope) {
  final transforms = find.descendant(
    of: scope,
    matching: find.byType(Transform),
  );
  if (transforms.evaluate().isEmpty) return null;
  return tester
      .widget<Transform>(transforms.first)
      .transform
      .getTranslation()
      .x;
}

WordLyricLineData _wline(String text, {int start = 0, String? sub}) =>
    WordLyricLineData(
      startMs: start,
      endMs: start + 4000,
      words: [WordLyricWord(startMs: start, endMs: start + 4000, text: text)],
      sub: sub,
    );

void main() {
  group('TimedLyricView: 行级歌词', () {
    testWidgets('超长当前行渲染滚动组件(不是纯 Text ellipsis)', (tester) async {
      await tester.pumpWidget(
        _host(
          TimedLyricView(
            lines: [_line(_long), _line(_short, ms: 5000)],
            activeIndex: 0,
            playing: ValueNotifier<bool>(false),
          ),
        ),
      );
      await tester.pump();

      expect(_scrollIn('lyric-line-0'), findsOneWidget);
      // 滚动中的那一段文本必须 overflow: visible(全文宽排版), 不能是 ellipsis
      final text = tester.widget<Text>(
        find.descendant(
          of: _scrollIn('lyric-line-0'),
          matching: find.byType(Text),
        ),
      );
      expect(text.overflow, TextOverflow.visible);
      expect(text.maxLines, 1);
    });

    testWidgets('非当前行保持单行省略号', (tester) async {
      await tester.pumpWidget(
        _host(
          TimedLyricView(
            lines: [_line(_short), _line(_long, ms: 5000)],
            activeIndex: 0,
            playing: ValueNotifier<bool>(false),
          ),
        ),
      );
      await tester.pump();

      expect(_scrollIn('lyric-line-1'), findsNothing);
      final text = tester.widget<Text>(
        find.descendant(
          of: find.byKey(const ValueKey('lyric-line-1')),
          matching: find.byType(Text),
        ),
      );
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, 1);
    });

    testWidgets('播放中才滚动: playing=true 位移递增, playing=false 冻结且不排帧', (
      tester,
    ) async {
      final playing = ValueNotifier<bool>(true);
      addTearDown(playing.dispose);
      await tester.pumpWidget(
        _host(
          TimedLyricView(
            lines: [_line(_long)],
            activeIndex: 0,
            playing: playing,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      final row = find.byKey(const ValueKey('lyric-line-0'));
      final p1 = _offsetX(tester, row);
      await tester.pump(const Duration(milliseconds: 400));
      final p2 = _offsetX(tester, row);
      expect(p1, isNotNull);
      expect(p2!, lessThan(p1!), reason: '播放中应向左滚');

      // 暂停: ticker 被 TickerMode 静音, 偏移冻结且不再排帧
      playing.value = false;
      await tester.pump();
      final paused = _offsetX(tester, row);
      await tester.pump(const Duration(seconds: 2));
      expect(_offsetX(tester, row), paused);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('300dp + 1.25 字号: 超长当前行 + 翻译都不溢出', (tester) async {
      await tester.pumpWidget(
        _host(
          TimedLyricView(
            lines: [
              _line(
                _long,
                sub: 'a very long translation line for narrow screens',
              ),
              _line(_short, ms: 5000),
            ],
            activeIndex: 0,
            playing: ValueNotifier<bool>(true),
          ),
          textScale: 1.25,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(tester.takeException(), isNull);
      expect(_scrollIn('lyric-line-0'), findsOneWidget);
      // 位移不能把内容推出它自己的行(ClipRect 在行内)
      expect(
        _offsetX(tester, find.byKey(const ValueKey('lyric-line-0'))),
        isNotNull,
      );
    });

    testWidgets('短句不滚(放得下就是静态居中文本)', (tester) async {
      await tester.pumpWidget(
        _host(
          TimedLyricView(
            lines: [_line('短句'), _line(_short, ms: 5000)],
            activeIndex: 0,
            playing: ValueNotifier<bool>(true),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(_scrollIn('lyric-line-0'), findsNothing);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('WordLyricView: 逐字歌词', () {
    testWidgets('超长当前行: 按全文宽排版并横向滚动(不是先 ellipsis 再平移)', (tester) async {
      final playing = ValueNotifier<bool>(true);
      addTearDown(playing.dispose);
      await tester.pumpWidget(
        _host(
          WordLyricView(
            lines: [_wline(_long), _wline(_short, start: 9000)],
            positionMs: ValueNotifier<int>(100),
            playing: playing,
            padding: EdgeInsets.zero,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));

      expect(_scrollIn('word-lyric-line-0'), findsOneWidget);
      final painter =
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(KaraokeLine),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as KaraokePainter;
      // 滚动分支不画省略号
      expect(painter.ellipsis, isFalse);

      final p1 = _offsetX(
        tester,
        find.byKey(const ValueKey('word-lyric-line-0')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      final p2 = _offsetX(
        tester,
        find.byKey(const ValueKey('word-lyric-line-0')),
      );
      expect(p1, isNotNull);
      expect(p2!, lessThan(p1!), reason: '播放中应向左滚');
    });

    testWidgets('暂停后当前行停在原位, 零排帧', (tester) async {
      final playing = ValueNotifier<bool>(false);
      addTearDown(playing.dispose);
      await tester.pumpWidget(
        _host(
          WordLyricView(
            lines: [_wline(_long)],
            positionMs: ValueNotifier<int>(100),
            playing: playing,
            padding: EdgeInsets.zero,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(_scrollIn('word-lyric-line-0'), findsOneWidget);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('非当前行的静态行仍是 ellipsis', (tester) async {
      await tester.pumpWidget(
        _host(
          WordLyricView(
            lines: [_wline(_short), _wline(_long, start: 9000)],
            positionMs: ValueNotifier<int>(0),
            playing: ValueNotifier<bool>(false),
            padding: EdgeInsets.zero,
          ),
        ),
      );
      await tester.pump();
      expect(_scrollIn('word-lyric-line-1'), findsNothing);
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const ValueKey('word-lyric-line-1')),
          matching: find.byType(RichText),
        ),
      );
      expect(rich.overflow, TextOverflow.ellipsis);
      expect(rich.maxLines, 1);
    });

    testWidgets('300dp + 1.25 字号: 超长当前行 + 翻译不溢出', (tester) async {
      await tester.pumpWidget(
        _host(
          WordLyricView(
            lines: [
              _wline(
                _long,
                sub: 'a very long translation line for narrow screens',
              ),
              _wline(_short, start: 9000),
            ],
            positionMs: ValueNotifier<int>(100),
            playing: ValueNotifier<bool>(true),
            padding: EdgeInsets.zero,
          ),
          textScale: 1.25,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1200));
      expect(tester.takeException(), isNull);
      expect(_scrollIn('word-lyric-line-0'), findsOneWidget);
    });
  });
}
