import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/marquee_text.dart';

Widget _host(String text, {bool reduceMotion = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 600),
        textScaler: const TextScaler.linear(1.25),
        disableAnimations: reduceMotion,
      ),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 300,
            child: InkWell(
              onTap: () {},
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: MarqueeText(
                  text,
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('超长歌名: textScale 1.25 下单行渲染, 不溢出不抛错', (tester) async {
    await tester.pumpWidget(_host('一首非常非常非常长的歌名' * 6));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.height, lessThan(40), reason: '必须是单行(竖排会远高于行高)');
    expect(tester.takeException(), isNull);
  });

  testWidgets('短歌名: 不启动动画(无 Transform, settle 后无新帧)', (tester) async {
    await tester.pumpWidget(_host('短名'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_marqueeTransform(tester), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('长歌名: 若干帧后文本发生位移(marquee 生效)', (tester) async {
    await tester.pumpWidget(_host('一首非常非常非常长的歌名' * 6));
    await tester.pump();
    // 动画在 post-frame 创建, 先跨过创建帧再观察位移
    await tester.pump(const Duration(milliseconds: 1100));
    final p1 = _marqueeOffset(tester);
    await tester.pump(const Duration(milliseconds: 400));
    final p2 = _marqueeOffset(tester);
    expect(p2, isNotNull);
    expect(p2!, lessThan(p1 ?? 0), reason: '文本应向左滚动');
  });

  testWidgets('reduce motion: 不打动画, 单行不溢出', (tester) async {
    await tester.pumpWidget(
      _host('一首非常非常非常长的歌名' * 6, reduceMotion: true),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_marqueeTransform(tester), findsNothing);
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.height, lessThan(40));
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  // 防回退: 详情页(歌词页)标题必须是 titleLarge 级别,
  // 歌单详情头卡标题必须是 headlineSmall 级别(之前被钉在 titleMedium 导致字号特别小).
  test('详情页标题字号防回退: main 用 titleLarge, detail_page 用 headlineSmall', () {
    final mainSrc = File('lib/main.dart').readAsStringSync();
    final detailSrc = File('lib/src/detail_page.dart').readAsStringSync();
    // 歌词页 AppBar titleTextStyle 不允许退回 titleMedium
    final appBarBlock = mainSrc.substring(
      mainSrc.indexOf('titleTextStyle:'),
      mainSrc.indexOf('title: MarqueeText'),
    );
    expect(appBarBlock.contains('titleLarge'), isTrue);
    expect(appBarBlock.contains('titleMedium'), isFalse);
    // 歌单详情头卡标题不允许退回 titleMedium
    final headerBlock = detailSrc.substring(
      detailSrc.indexOf('MarqueeText(\n                        d?.name'),
    );
    expect(headerBlock.contains('headlineSmall'), isTrue);
  });
}

/// 只看 MarqueeText 子树里的 Transform(框架其它地方也可能有 Transform).
Finder _marqueeTransform(WidgetTester tester) => find.descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(Transform),
    );

double? _marqueeOffset(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(_marqueeTransform(tester));
  if (transforms.isEmpty) return null;
  return transforms.last.transform.getTranslation().x;
}
