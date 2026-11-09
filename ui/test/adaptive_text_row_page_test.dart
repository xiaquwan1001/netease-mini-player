// 播放条/顶栏 页面级(结构等价)窄宽回归: 300/320/360 × 1.0/1.25/1.625 无 overflow.
// _buildPlayerBar/_buildTopBar 依赖 Rust FFI 播放宿主, 测试无法注入假状态;
// 按 main.dart 播放条曲名行/顶栏的真实排版结构(AdaptiveTextRow + 进度行 +
// 图标钮; AppBar + MarqueeText + leading/actions)做结构等价回归.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/adaptive_text_row.dart';
import 'package:minincm/src/marquee_text.dart';
import 'package:minincm/src/song_tile.dart';

const _longName = '魔法未来2019主题歌Magia[Quartet]Live.Ver超长歌名继续加长再加长一点直到溢出为止啊';
const _widths = [300.0, 320.0, 360.0];
const _scales = [1.0, 1.25, 1.625];

Future<List<String>> pumpAudited(
  WidgetTester tester,
  Widget child, {
  required double width,
  required double scale,
}) async {
  tester.view.physicalSize = Size(width, 700);
  tester.view.devicePixelRatio = 1;
  tester.view.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  final errors = <FlutterErrorDetails>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (d) => errors.add(d);
  try {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
  } finally {
    FlutterError.onError = previous;
  }
  return [for (final e in errors) e.exception.toString()];
}

Widget playerBar({required String title, required List<Widget> badges}) {
  // 与 main.dart _buildPlayerBar 同构: 封面 + 文本块(曲名行 + 进度行) + 图标钮
  return Material(
    child: SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Slider(value: 0.3, max: 1, onChanged: null),
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  child: Container(width: 40, height: 40, color: Colors.grey),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 8, 4),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AdaptiveTextRow(
                          title: title,
                          style: const TextStyle(fontSize: 14),
                          badges: badges,
                        ),
                        Text(
                          '03:15 / 04:29  周杰伦  1/25',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(onPressed: () {}, icon: const Icon(Icons.favorite_border, size: 22)),
                IconButton(onPressed: () {}, icon: const Icon(Icons.skip_previous, size: 26)),
                IconButton(onPressed: () {}, icon: const Icon(Icons.play_circle, size: 38)),
                IconButton(onPressed: () {}, icon: const Icon(Icons.skip_next, size: 26)),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

void expectNoOverflow(List<String> errors, String tag) {
  final overflows = errors.where((e) => e.contains('overflowed')).toList();
  expect(overflows, isEmpty, reason: tag);
}

void main() {
  testWidgets('播放条(无曲目): 9 组合无溢出', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = 'PlayerBar-empty w=$width s=$scale';
        final errors = await pumpAudited(
          tester,
          playerBar(title: '未在播放', badges: const []),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('播放条(超长歌名+VIP标): 9 组合无溢出, 曲名单行', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = 'PlayerBar-vip w=$width s=$scale';
        final errors = await pumpAudited(
          tester,
          playerBar(
            title: _longName,
            badges: const [VipBadge(small: true), PaidBadge()],
          ),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
        expect(box.size.height, lessThan(40), reason: tag);
        expect(box.size.width, greaterThan(0), reason: tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('播放条(普通长歌名, 无徽标): 9 组合无溢出', (tester) async {
    for (final width in _widths) {
      for (final scale in _scales) {
        final tag = 'PlayerBar-plain w=$width s=$scale';
        final errors = await pumpAudited(
          tester,
          playerBar(title: _longName, badges: const []),
          width: width,
          scale: scale,
        );
        expectNoOverflow(errors, tag);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });

  testWidgets('顶栏(歌词页态: 标题+收起+分享/翻译/菜单; 歌单浏览态: 标题+返回): 9 组合无溢出, 标题单行',
      (tester) async {
    final actions = [
      IconButton(onPressed: () {}, icon: const Icon(Icons.share)),
      IconButton(onPressed: () {}, icon: const Icon(Icons.translate)),
      IconButton(onPressed: () {}, icon: const Icon(Icons.more_vert)),
    ];
    for (final width in _widths) {
      for (final scale in _scales) {
        for (final entry in {'lyrics': actions, 'library': <Widget>[]}.entries) {
          final tag = 'TopBar-${entry.key} w=$width s=$scale';
          final errors = await pumpAudited(
            tester,
            Scaffold(
              appBar: AppBar(
                titleTextStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                title: MarqueeText(_longName),
                leading: IconButton(
                  onPressed: () {},
                  icon: Icon(entry.key == 'lyrics' ? Icons.expand_more : Icons.arrow_back),
                ),
                actions: entry.value,
              ),
              body: const SizedBox.expand(),
            ),
            width: width,
            scale: scale,
          );
          expectNoOverflow(errors, tag);
          final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
          expect(box.size.height, lessThan(60), reason: tag);
          expect(box.size.width, greaterThan(0), reason: tag);
          // 返回/收起按钮必须仍在
          expect(find.byIcon(Icons.expand_more), entry.key == 'lyrics' ? findsOneWidget : findsNothing);
          expect(find.byIcon(Icons.arrow_back), entry.key == 'library' ? findsOneWidget : findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
  });
}
