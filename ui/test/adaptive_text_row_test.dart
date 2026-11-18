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
  group('shouldShowBadgesForWidth 纯函数(阈值判定, 现口径: 行宽 - 徽标宽)', () {
    test('默认阈值 120: 60/80/119.9 隐藏, 120/121/200 显示(无徽标占用)', () {
      // 迁移自旧的 shouldShowBadges(可用宽) 版本: 徽标宽 0 时新函数等价于旧函数,
      // 所以原来的每一档宽度断言都保留。
      expect(shouldShowBadgesForWidth(60, 0), isFalse);
      expect(shouldShowBadgesForWidth(80, 0), isFalse);
      expect(shouldShowBadgesForWidth(119.9, 0), isFalse);
      expect(shouldShowBadgesForWidth(120, 0), isTrue);
      expect(shouldShowBadgesForWidth(121, 0), isTrue);
      expect(shouldShowBadgesForWidth(200, 0), isTrue);

      // 空徽标列表: 占用 0 宽, 判定退回整行宽(与上面同一组边界)
      expect(badgeGroupWidth(const []), 0);
      expect(titleAvailableWidth(200, badgeGroupWidth(const [])), 200);
      expect(
        shouldShowBadgesForWidth(119.9, badgeGroupWidth(const [])),
        isFalse,
      );
      expect(shouldShowBadgesForWidth(120, badgeGroupWidth(const [])), isTrue);

      // 新口径才有的部分: 徽标宽从行宽里扣掉后才比阈值
      // (旧版按整行宽判定, 行宽 200 / 徽标 72 会误判"够宽")
      expect(titleAvailableWidth(130, 72), 58);
      expect(badgeGroupWidth([68], gap: 4), 72);
      expect(
        shouldShowBadgesForWidth(200, 72),
        isTrue,
        reason: '可用宽 128 >= 120',
      );
      expect(
        shouldShowBadgesForWidth(191.9, 72),
        isFalse,
        reason: '可用宽 119.9 < 120(整行宽 191.9 按旧口径会误判)',
      );
      expect(shouldShowBadgesForWidth(192, 72), isTrue, reason: '可用宽恰好 120');
    });
    test('自定义阈值生效 + 徽标宽超过行宽时钳 0', () {
      expect(shouldShowBadgesForWidth(100, 10, threshold: 90), isTrue); // 可用 90
      expect(shouldShowBadgesForWidth(99, 10, threshold: 90), isFalse); // 可用 89
      expect(shouldShowBadgesForWidth(0, 0), isFalse);
      // 徽标比行还宽: 可用宽钳到 0(不是负数) ⇒ 默认阈值下隐藏;
      // 阈值 0 时仍算达标(0 >= 0) —— 这一条同时证明钳位没留下负值。
      expect(titleAvailableWidth(60, 139), 0);
      expect(shouldShowBadgesForWidth(60, 139), isFalse);
      expect(shouldShowBadgesForWidth(60, 139, threshold: 0), isTrue);
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
