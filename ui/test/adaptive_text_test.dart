// AdaptiveText 单测: 溢出死区/单向滚动(跑马灯内核)、徽标口径(标题实际可用宽)、
// 显式 style 与继承 DefaultTextStyle 的判定一致性.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/adaptive_text.dart';
import 'package:minincm/src/marquee_text.dart';

const _style = TextStyle(fontSize: 16);
const _scaler = TextScaler.linear(1.25);

/// 用与渲染一致的 style/textScaler 量单行宽度(与 MarqueeText 内部同口径).
double _measureWidth(String text, TextStyle style, TextScaler scaler) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout();
  final width = tp.width;
  tp.dispose();
  return width;
}

Widget _host(
  Widget child, {
  required double width,
  TextScaler scaler = _scaler,
}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: const Size(600, 600), textScaler: scaler),
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

/// 只看 AdaptiveText/MarqueeText 子树里的 Transform.
Finder _marqueeTransform() => find.descendant(
  of: find.byType(MarqueeText),
  matching: find.byType(Transform),
);

double? _marqueeOffset(WidgetTester tester) {
  final transforms = tester.widgetList<Transform>(_marqueeTransform());
  if (transforms.isEmpty) return null;
  return transforms.last.transform.getTranslation().x;
}

void main() {
  group('纯函数(判定口径)', () {
    test('标题实际可用宽 = 行宽 - 徽标组宽(行宽 130 / Σ徽标 72 ⇒ 58)', () {
      expect(titleAvailableWidth(130, 72), 58);
      // 徽标组宽 = Σ徽标宽 + 每个徽标前的间距
      expect(badgeGroupWidth([68], gap: 4), 72);
      expect(badgeGroupWidth([30, 20], gap: 4), 58);
    });

    test('负可用宽钳 0', () {
      expect(titleAvailableWidth(60, 139), 0);
    });

    test('徽标判定用标题可用宽, 不是整行宽', () {
      // 行宽 130 按整行宽看远超阈值 120(旧口径: 显示徽标), 但标题只剩 58px
      expect(shouldShowBadgesForWidth(130, 72), isFalse);
      // 标题可用宽够阈值时才显示
      expect(shouldShowBadgesForWidth(200, 72), isTrue);
      expect(shouldShowBadgesForWidth(200, 72, threshold: 200), isFalse);
    });

    test('只有 marquee 形态需要滚动内核', () {
      expect(needsMarquee(AdaptiveTextMode.marquee), isTrue);
      expect(needsMarquee(AdaptiveTextMode.ellipsis), isFalse);
      expect(needsMarquee(AdaptiveTextMode.wrap), isFalse);
    });
  });

  group('跑马灯判定(溢出死区 / 单向)', () {
    testWidgets('溢出 3px < 死区(8px): 不滚(无 Transform)', (tester) async {
      const text = '刚好差三像素的歌名';
      final textWidth = _measureWidth(text, _style, _scaler);
      await tester.pumpWidget(
        _host(const AdaptiveText(text, style: _style), width: textWidth - 3),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(_marqueeTransform(), findsNothing, reason: '死区内的溢出不该滚');
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('溢出 40px: 滚且单向(只有回跳, 无缓慢回滚)', (tester) async {
      const text = '一二三四五六七八九十一二三四五六七';
      final textWidth = _measureWidth(text, _style, _scaler);
      await tester.pumpWidget(
        _host(const AdaptiveText(text, style: _style), width: textWidth - 40),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      expect(_marqueeTransform(), findsOneWidget, reason: '溢出远大于死区应滚动');

      final samples = <double>[];
      for (var i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final o = _marqueeOffset(tester);
        if (o != null) samples.add(o);
      }
      expect(samples.length, greaterThan(50), reason: '应当一直在滚动');
      var jumps = 0;
      for (var i = 1; i < samples.length; i++) {
        final d = samples[i] - samples[i - 1];
        if (d > 1.0) {
          jumps++;
          expect(d, greaterThan(20), reason: '正向位移只能是回跳(瞬跳), 不能是缓慢回滚');
        }
      }
      expect(jumps, greaterThanOrEqualTo(1), reason: '6s 窗口内应至少循环一次');
    });
  });

  group('徽标口径(标题实际可用宽)', () {
    testWidgets('行宽 130 / Σ徽标 72: 徽标整组收起, 标题拿到全宽(>0)', (tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveText(
            '徽标很宽的歌名',
            style: _style,
            badges: [SizedBox(width: 68, height: 16, child: Text('VIP'))],
          ),
          width: 130,
        ),
      );
      // 首帧测量徽标宽, 下一帧给出收起结论
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('VIP'), findsNothing, reason: '标题只剩 58px < 阈值 120 ⇒ 收起');
      final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
      expect(box.size.width, greaterThan(0));
      expect(box.size.width, closeTo(130, 0.5), reason: '收起徽标后标题应拿到整行宽');
    });

    testWidgets('行宽 400 / Σ徽标 72: 标题可用宽 328 > 阈值, 徽标保留', (tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveText(
            '徽标很宽的歌名',
            style: _style,
            badges: [SizedBox(width: 68, height: 16, child: Text('VIP'))],
          ),
          width: 400,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('VIP'), findsOneWidget);
      final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
      expect(box.size.width, closeTo(400 - 72, 0.5));
    });
  });

  group('显式 style 与继承 DefaultTextStyle', () {
    // 同一文本, 同样 20sp: 一个显式 style, 一个只继承 DefaultTextStyle,
    // "是否滚动"的结论必须一致(测量合并 DefaultTextStyle 那条修复的延伸回归).
    Widget inherited(
      String text, {
      required double width,
      double fontSize = 20,
    }) {
      return MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(600, 600), textScaler: _scaler),
          // DefaultTextStyle 必须放在 Material/Scaffold 之内, 否则会被覆盖
          child: Scaffold(
            body: DefaultTextStyle(
              style: TextStyle(fontSize: fontSize),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(width: width, child: AdaptiveText(text)),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('溢出场景: 两种写法都滚', (tester) async {
      const text = '一二三四五六七八九十';
      await tester.pumpWidget(
        _host(
          const AdaptiveText(text, style: TextStyle(fontSize: 20)),
          width: 200,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      final explicit = _marqueeTransform().evaluate().isEmpty ? false : true;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(inherited(text, width: 200));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1100));
      final fromDefaultStyle = _marqueeTransform().evaluate().isNotEmpty;

      expect(explicit, isTrue);
      expect(fromDefaultStyle, isTrue, reason: '继承 20sp 时按 14sp 量会误判放得下');
      expect(fromDefaultStyle, explicit, reason: '两种写法结论必须一致');
    });

    testWidgets('放得下场景: 两种写法都不滚', (tester) async {
      const text = '一二三四五六七八九十';
      await tester.pumpWidget(
        _host(
          const AdaptiveText(text, style: TextStyle(fontSize: 20)),
          width: 400,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final explicit = _marqueeTransform().evaluate().isNotEmpty;

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(inherited(text, width: 400));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final fromDefaultStyle = _marqueeTransform().evaluate().isNotEmpty;

      expect(explicit, isFalse);
      expect(fromDefaultStyle, isFalse);
      expect(fromDefaultStyle, explicit, reason: '两种写法结论必须一致');
    });
  });

  group('非 marquee 形态', () {
    testWidgets('ellipsis: 单行静态, 无滚动内核', (tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveText(
            '很长很长的标题继续加长直到溢出为止啊',
            mode: AdaptiveTextMode.ellipsis,
            style: _style,
          ),
          width: 120,
        ),
      );
      await tester.pump();
      expect(find.byType(MarqueeText), findsNothing);
      final box = tester.renderObject<RenderBox>(find.byType(Text));
      expect(box.size.height, lessThan(40), reason: '必须单行');
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('wrap maxLines: 2: 两行且不滚', (tester) async {
      await tester.pumpWidget(
        _host(
          const AdaptiveText(
            '很长很长的标题继续加长直到溢出为止啊很长很长的标题继续加长',
            mode: AdaptiveTextMode.wrap,
            maxLines: 2,
            style: _style,
          ),
          width: 120,
        ),
      );
      await tester.pump();
      expect(find.byType(MarqueeText), findsNothing);
      final box = tester.renderObject<RenderBox>(find.byType(Text));
      expect(box.size.height, greaterThan(40), reason: '两行应高于单行');
      expect(box.size.height, lessThan(80), reason: '不允许超过两行');
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });
}
