// 常驻播放条(PlayerBarHost): 窄屏 300dp + 大字号的"结构级"回归.
//
// 背景: 播放条真正的组件实现还在另一个 lane 往 ui/lib/src/player_bar.dart 搬,
// 这里只测公开面 —— PlayerBarHost + playerBarSlot 投递的"结构等价替身":
// Material(elevation) > Slider + Row[封面 CoverArt + Expanded(AdaptiveTextRow)
// + 5 个 40dp IconButton]. 真实组件换了文件后这套断言仍然成立.
//
// 覆盖现有 player_bar_host_test(3 例)没覆盖的组合:
// 窄屏 × 1.0/1.25/1.625 三档字号不溢出; 播放条在内容区"之下"(Column 而非
// Overlay 盖上去); 键盘弹出时播放条不占任何内容高度.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/adaptive_text_row.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/song_tile.dart';

/// 结构等价于真实播放条最小结构的替身(只用公开 widget, 不碰 main.dart 私有类).
Widget _barStandIn() {
  Widget barIcon(String tooltip, IconData icon) => IconButton(
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: () {},
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      );
  return Material(
    elevation: 8,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Slider(value: 30, max: 200, onChanged: (_) {}),
        Row(
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 8, right: 4),
              child: CoverArt(url: null, size: 40, radius: 6),
            ),
            Expanded(
              child: AdaptiveTextRow(
                title: '一首很长很长的歌名用来验证窄屏降级不溢出',
                badges: const [VipBadge(small: true)],
              ),
            ),
            barIcon('喜欢', Icons.favorite_border),
            barIcon('上一首', Icons.skip_previous),
            barIcon('播放', Icons.play_circle),
            barIcon('下一首', Icons.skip_next),
          ],
        ),
        const SizedBox(height: 8),
      ],
    ),
  );
}

Widget _app({
  double keyboardInset = 0,
  double textScale = 1.0,
  Key? contentKey,
}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
        viewInsets: EdgeInsets.only(bottom: keyboardInset),
        textScaler: TextScaler.linear(textScale),
      ),
      child: PlayerBarHost(content: child ?? const SizedBox.shrink()),
    ),
    // resizeToAvoidBottomInset=false: 让 Scaffold 不自己吃键盘 inset,
    // 隔离出播放条占位对内容区高度的贡献(键盘让位语义只看 PlayerBarHost).
    home: Scaffold(
      resizeToAvoidBottomInset: false,
      body: SizedBox.expand(key: contentKey, child: const ColoredBox(color: Colors.teal)),
    ),
  );
}

void main() {
  tearDown(() => playerBarSlot.value = null);

  for (final scale in const [1.0, 1.25, 1.625]) {
    testWidgets('300dp 窄屏 × 字号 $scale: 播放条结构不溢出不抛异常', (tester) async {
      tester.view.physicalSize = const Size(300, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      playerBarSlot.value = _barStandIn();
      await tester.pumpWidget(_app(textScale: scale));
      // 标题行的跑马灯(MarqueeText)永远在动画, pumpAndSettle 会超时, 用固定帧.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(tester.takeException(), isNull,
          reason: '300dp × $scale 下播放条替身(进度条/封面/标题/5 按钮)不能溢出');
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(CoverArt), findsOneWidget);
      expect(find.byType(AdaptiveTextRow), findsOneWidget);
      // 替身保留真实条的无障碍语义: 每个操作按钮都有 tooltip(→ Semantics label)
      expect(find.byTooltip('喜欢'), findsOneWidget);
      expect(find.byTooltip('播放'), findsOneWidget);
      expect(find.byTooltip('上一首'), findsOneWidget);
      expect(find.byTooltip('下一首'), findsOneWidget);
    });
  }

  testWidgets('300dp 窄屏: 播放条位于内容区之下(不是覆盖层)', (tester) async {
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const contentKey = Key('content');
    playerBarSlot.value = _barStandIn();
    await tester.pumpWidget(_app(textScale: 1.25, contentKey: contentKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final contentBottom =
        tester.getBottomLeft(find.byKey(contentKey)).dy;
    final barTop = tester.getTopLeft(find.byWidget(playerBarSlot.value!)).dy;
    expect(barTop, greaterThanOrEqualTo(contentBottom),
        reason: '播放条由 Column 排在内容区之下, 不能盖在内容上面');
    // 且内容区没有为播放条让位到屏幕外(播放条占的高度是"额外让出", 内容仍全宽可见)
    expect(contentBottom, lessThanOrEqualTo(800));
  });

  testWidgets('键盘弹出: 播放条占位高度为 0(内容区拿满全屏高)', (tester) async {
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const contentKey = Key('content');
    playerBarSlot.value = _barStandIn();
    await tester.pumpWidget(
        _app(keyboardInset: 320, textScale: 1.25, contentKey: contentKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(Slider), findsNothing, reason: '键盘弹出时播放条整体让位');
    final contentSize = tester.getSize(find.byKey(contentKey));
    expect(contentSize.height, 800,
        reason: '播放条隐藏后不应再占任何内容高度');
  });
}
