// 固定行高列表(itemExtent)在放大字号下的行高回归。
//
// 背景: `SliverFixedExtentList` / `ListView(itemExtent:)` 的行高是硬约束, 内容比它高
// 就被从下方裁掉并抛 RenderFlex vertical overflow。v0.9.0 实测: detail_page 曲目行
// 定 56dp 时, 1.625 字号下「标题 + 2 + 徽标+副标题」竖溢 12dp。
//
// 这里验证三件事(都是可证伪的):
//   ① `rowExtentFor` = 基准 × textScaler, 上限 2 倍(与歌词行高同口径);
//   ② 同一份行内容塞进 56dp 在 1.625 下**确实**溢出(负向对照, 证明修复不是空跑);
//   ③ 塞进 `rowExtentFor` 的行高后 1.0/1.3/1.625/2.0 四档都不溢出。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/adaptive_text_row.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/lyric.dart';
import 'package:minincm/src/song_tile.dart';

/// 与 `detail_page.dart::_SongRow` 的文本列同构: 标题(单行) + 2 + 徽标行 + 副标题。
/// 徽标放副标题行是 A 级修复后的真实结构(VIP/付费/无版权), 它决定行的自然高。
Widget _detailRowContent() => Padding(
  padding: const EdgeInsets.only(left: 12, right: 4),
  child: Row(
    children: [
      const SizedBox(width: 26, child: Text('01', textAlign: TextAlign.right)),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AdaptiveTextRow(title: '超长曲目名称占位用来测行高', marquee: false),
            const SizedBox(height: 2),
            Row(
              children: [
                const VipBadge(small: true),
                const Expanded(
                  child: Text(
                    '某艺人 · 某专辑',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  ),
);

/// 在 `height` 的硬约束里渲染行内容, 返回捕获到的 overflow 文案。
Future<List<String>> _pumpInExtent(
  WidgetTester tester, {
  required double scale,
  required double height,
}) async {
  tester.view.physicalSize = const Size(300, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d.exceptionAsString());
  try {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: const Size(300, 700),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(height: height, child: _detailRowContent()),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  } finally {
    FlutterError.onError = previous;
  }
  return errors;
}

void main() {
  group('rowExtentFor', () {
    testWidgets('= 基准 × textScaler, 上限 2 倍', (tester) async {
      final values = <double, double>{};
      for (final scale in const [1.0, 1.25, 1.3, 1.625, 2.0, 3.0]) {
        await tester.pumpWidget(
          MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Builder(
              builder: (context) {
                values[scale] = rowExtentFor(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
      }
      expect(values[1.0], kRowExtent, reason: '基准字号下就是 56, 既有几何不动');
      expect(values[1.25], closeTo(70, 0.01));
      expect(values[1.3], closeTo(72.8, 0.01));
      expect(values[1.625], closeTo(91, 0.01));
      expect(values[2.0], closeTo(112, 0.01));
      expect(values[3.0], closeTo(112, 0.01), reason: '上限 2 倍(3.0 不许无限放大)');
    });

    testWidgets('自定义基准同样按字号放大', (tester) async {
      late double got;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Builder(
            builder: (context) {
              got = rowExtentFor(context, 40);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(got, closeTo(60, 0.01));
    });
  });

  group('曲目行行高(负向对照 + 修复后)', () {
    testWidgets('1.625 字号: 定高 56 确实竖溢(证明修复有对象)', (tester) async {
      final errors = await _pumpInExtent(tester, scale: 1.625, height: 56);
      expect(
        errors.where((m) => m.contains('overflowed')),
        isNotEmpty,
        reason: '这条是本项的原始 bug: 56dp 装不下 1.625 字号的两行文本',
      );
    });

    for (final scale in const [1.0, 1.3, 1.625, 2.0]) {
      testWidgets('$scale 字号: 用 rowExtentFor 的行高不溢出', (tester) async {
        final errors = await _pumpInExtent(
          tester,
          scale: scale,
          height: kRowExtent * scale,
        );
        expect(
          errors.where((m) => m.contains('overflowed')),
          isEmpty,
          reason: '$scale 字号下行高必须按 textScaler 放大',
        );
        final title = tester.renderObject<RenderBox>(
          find.text('超长曲目名称占位用来测行高'),
        );
        expect(title.size.height, lessThan(24 * scale), reason: '标题必须单行');
      });
    }
  });

  group('歌词视图缺省行高', () {
    testWidgets('TimedLyricView 不传 itemExtent 时按字号放大', (tester) async {
      tester.view.physicalSize = const Size(300, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.625)),
            child: TimedLyricView(
              lines: [
                ParsedLyricLine(timeMs: BigInt.zero, text: '第一句'),
                ParsedLyricLine(timeMs: BigInt.from(5000), text: '第二句'),
              ],
              activeIndex: 0,
            ),
          ),
        ),
      );
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.itemExtent, closeTo(91, 0.01), reason: '1.625 × 56 = 91');
      expect(tester.takeException(), isNull);
    });
  });
}
