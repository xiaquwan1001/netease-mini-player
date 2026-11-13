// AdaptiveTextRow 单元/组件测试: 徽标阈值、标题永不 0 宽、marquee 路径.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:minincm/src/adaptive_text_row.dart';
import 'package:minincm/src/marquee_text.dart';

const _longName = '魔法未来2019主题歌Magia[Quartet]Live.Ver超长歌名继续加长再加长一点直到溢出为止啊';

Widget host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Align(alignment: Alignment.topLeft, child: child),
  ),
);

Future<void> pump(WidgetTester tester, Widget child, {double? width}) async {
  if (width != null) {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(host(child));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  group('shouldShowBadges 纯函数(阈值判定)', () {
    test('默认阈值 120: 60/80/119 隐藏, 120/121/200 显示', () {
      expect(shouldShowBadges(60), isFalse);
      expect(shouldShowBadges(80), isFalse);
      expect(shouldShowBadges(119.9), isFalse);
      expect(shouldShowBadges(120), isTrue);
      expect(shouldShowBadges(121), isTrue);
      expect(shouldShowBadges(200), isTrue);
    });
    test('自定义阈值生效', () {
      expect(shouldShowBadges(100, threshold: 90), isTrue);
      expect(shouldShowBadges(89, threshold: 90), isFalse);
      expect(shouldShowBadges(0), isFalse);
    });
  });

  testWidgets('宽度 60: 徽标隐藏, 标题占满且单行(宽>0, 不竖排)', (tester) async {
    await pump(
      tester,
      const AdaptiveTextRow(title: _longName, badges: [Text('VIP')]),
      width: 60,
    );
    expect(find.text('VIP'), findsNothing);
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.width, greaterThan(40));
    expect(box.size.width, lessThanOrEqualTo(60));
    expect(box.size.height, lessThan(40));
  });

  testWidgets('宽度 80: 徽标隐藏; 宽度 200: 徽标显示', (tester) async {
    await pump(
      tester,
      const AdaptiveTextRow(title: _longName, badges: [Text('VIP')]),
      width: 80,
    );
    expect(find.text('VIP'), findsNothing);

    // 换宽前先卸载: MarqueeText 对同一 State 快速变宽会二次建 ticker(既有隐患)
    await tester.pumpWidget(const SizedBox.shrink());
    await pump(
      tester,
      const AdaptiveTextRow(title: _longName, badges: [Text('VIP')]),
      width: 200,
    );
    expect(find.text('VIP'), findsOneWidget);
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.width, greaterThan(100));
  });

  testWidgets('自定义阈值: badgeCollapseBelow=200 时 150 隐藏, 300 显示', (tester) async {
    await pump(
      tester,
      const AdaptiveTextRow(
        title: _longName,
        badges: [Text('VIP')],
        badgeCollapseBelow: 200,
      ),
      width: 150,
    );
    expect(find.text('VIP'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    // 口径(本车道修正): 判据是「标题实际可用宽」= 行宽 - Σ徽标宽, 不是整行宽.
    // 测试字体每个字符宽 = fontSize(14), 'VIP' = 42 + 4 间距 = 46:
    //   行宽 240 ⇒ 标题可用 194 < 200 ⇒ 仍然收起(旧口径按整行 240 会误判"够宽");
    await pump(
      tester,
      const AdaptiveTextRow(
        title: _longName,
        badges: [Text('VIP')],
        badgeCollapseBelow: 200,
      ),
      width: 240,
    );
    expect(find.text('VIP'), findsNothing, reason: '标题可用宽 194 < 阈值 200');
    await tester.pumpWidget(const SizedBox.shrink());
    // 行宽 300 ⇒ 标题可用 254 >= 200 ⇒ 显示
    await pump(
      tester,
      const AdaptiveTextRow(
        title: _longName,
        badges: [Text('VIP')],
        badgeCollapseBelow: 200,
      ),
      width: 300,
    );
    expect(find.text('VIP'), findsOneWidget);
  });

  testWidgets('超长标题走 marquee; marquee:false 退化为单行 ellipsis', (tester) async {
    await pump(tester, const AdaptiveTextRow(title: _longName), width: 200);
    // MarqueeText 在, 且测量出需要滚动(动画 controller 已挂)
    expect(find.byType(MarqueeText), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));

    await tester.pumpWidget(const SizedBox.shrink());
    await pump(
      tester,
      const AdaptiveTextRow(title: _longName, marquee: false),
      width: 200,
    );
    expect(find.byType(MarqueeText), findsNothing);
    final box = tester.renderObject<RenderBox>(find.byType(Text));
    expect(box.size.height, lessThan(40));
  });

  testWidgets('SongTile 用的组件路径: 窄宽 60 下多徽标整组隐藏且标题不 0 宽', (tester) async {
    await pump(
      tester,
      const AdaptiveTextRow(
        title: _longName,
        badges: [Text('VIP'), Text('付费'), Text('无版权'), Icon(Icons.favorite)],
      ),
      width: 60,
    );
    expect(find.text('VIP'), findsNothing);
    expect(find.text('付费'), findsNothing);
    expect(find.text('无版权'), findsNothing);
    expect(find.byIcon(Icons.favorite), findsNothing);
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.width, greaterThan(40));
  });

  testWidgets('宽徽标组也不把标题压到 0 宽(312 阈值边界之上仍安全)', (tester) async {
    // 徽标总宽 150, 可用 160: 阈值判定放行, Expanded 保证标题仍有空间
    await pump(
      tester,
      const AdaptiveTextRow(
        title: _longName,
        badges: [SizedBox(width: 146, child: Text('VIP'))],
      ),
      width: 160,
    );
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.width, greaterThan(0));
  });

  testWidgets('300dp 视口 + 1.25 字号: 徽标与长标题不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: AdaptiveTextRow(title: _longName, badges: [Text('VIP')]),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('VIP'), findsOneWidget, reason: '300dp 高于默认阈值 120, 徽标保留');
    final box = tester.renderObject<RenderBox>(find.byType(MarqueeText));
    expect(box.size.width, greaterThan(0));
    expect(box.size.width, lessThanOrEqualTo(300));
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: home,
    ),
  );
}
