// MarqueeText 宽度快速连续变化压力测试:
// 旧实现在宽度连续变化时, 同一 State 可能经两次 addPostFrameCallback 各建一个
// AnimationController => SingleTickerProviderStateMixin "multiple tickers" 断言。
// 修复后 _start 带在途守卫(_startScheduled), 同一时刻最多一个在途回调。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/marquee_text.dart';

final _longText = '一首非常非常非常长的歌名' * 6;

Widget host(String text, double width) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(size: Size(400, 600)),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: MarqueeText(text, style: const TextStyle(fontSize: 16)),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 长文本是否处于滚动态(存在位移 Transform)
bool scrolling(WidgetTester tester) => find
    .descendant(
      of: find.byType(MarqueeText),
      matching: find.byType(Transform),
    )
    .evaluate()
    .isNotEmpty;

double? offsetX(WidgetTester tester) {
  final transforms = find
      .descendant(of: find.byType(MarqueeText), matching: find.byType(Transform));
  if (transforms.evaluate().isEmpty) return null;
  final t = tester.widget<Transform>(transforms.first);
  return t.transform.getTranslation().x;
}

void main() {
  testWidgets('长文本: 宽度连续 300→200→150→120→80 不抛 multiple tickers, 最终仍滚动', (tester) async {
    await tester.pumpWidget(host(_longText, 300));
    await tester.pump();
    for (final w in const [200.0, 150.0, 120.0, 80.0]) {
      await tester.pumpWidget(host(_longText, w));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 30));
      expect(tester.takeException(), isNull, reason: '宽度变化到 $w 不应抛断言');
    }
    await tester.pump(const Duration(milliseconds: 1100));
    expect(scrolling(tester), isTrue, reason: '80px 下长文本应继续滚动');
  });

  testWidgets('长→短: 宽度不变文本变短后停止滚动(无 Transform, 不再排帧)', (tester) async {
    await tester.pumpWidget(host(_longText, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(scrolling(tester), isTrue);
    await tester.pumpWidget(host('短名', 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.takeException(), isNull);
    expect(scrolling(tester), isFalse);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.binding.hasScheduledFrame, isFalse, reason: '停止后不应继续排帧');
  });

  testWidgets('短→长: 从不滚切换到滚动, 最终状态正确', (tester) async {
    await tester.pumpWidget(host('短名', 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(scrolling(tester), isFalse);
    await tester.pumpWidget(host(_longText, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    expect(tester.takeException(), isNull);
    expect(scrolling(tester), isTrue);
  });

  testWidgets('滚动中宽度抖动(80↔150 交替)不抛断言且可恢复滚动', (tester) async {
    await tester.pumpWidget(host(_longText, 150));
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pumpWidget(host(_longText, 80));
      await tester.pump();
      await tester.pumpWidget(host(_longText, 150));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '第 $i 轮抖动不应抛 multiple tickers');
    }
    await tester.pump(const Duration(milliseconds: 1100));
    expect(scrolling(tester), isTrue, reason: '抖动后长文本仍应滚动');
  });

  testWidgets('滚动中变小: 120→80 后按 80 视口继续向左滚动', (tester) async {
    await tester.pumpWidget(host(_longText, 120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1100));
    final p1 = offsetX(tester);
    expect(p1, isNotNull);
    await tester.pumpWidget(host(_longText, 80));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    expect(tester.takeException(), isNull);
    final p2 = offsetX(tester);
    expect(p2, isNotNull);
    expect(p2!, lessThan(p1!), reason: '最终宽度 80 下应继续向左滚动');
  });

  testWidgets('reduce motion: 宽度连续变化不建动画也不抛断言', (tester) async {
    Widget rmHost(double width) => MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(400, 600),
              disableAnimations: true,
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: MarqueeText(_longText, style: const TextStyle(fontSize: 16)),
                  ),
                ),
              ),
            ),
          ),
        );
    await tester.pumpWidget(rmHost(300));
    await tester.pump();
    for (final w in const [200.0, 150.0, 120.0, 80.0]) {
      await tester.pumpWidget(rmHost(w));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(scrolling(tester), isFalse, reason: 'reduce motion 不应滚动');
    }
    await tester.pump(const Duration(seconds: 3));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
