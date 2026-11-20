// B3a 回归(2026-11-19 用户反馈): 每日推荐页三个页签在 300dp + textScale 1.25 下
// 被裁字。
//
// 根因: TabBar 默认(isScrollable: false)把屏宽三等分 ⇒ 每格约 100dp, 而 4 个汉字
// + 默认 labelPadding(16×2 = 32)在 1.25 字号下需要 >100dp, 末尾字被裁。
// 修法: TabBar(isScrollable: true, tabAlignment: TabAlignment.start) + labelPadding 12,
// 页签保持自然宽度可横向拖; 仍是 TabBar 自己的指示器/联动(没有换成自写 chip 行)。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

const _labels = <String>['推荐歌曲', '推荐歌单', '历史日推'];

Widget _page({int initialTab = 0}) => MaterialApp(
  home: DailyRecommendPage(
    loadSongs: () async => const <rust.SongDto>[],
    loadPlaylists: () async => const <rust.Playlist>[],
    loadHistoryDates: () async => const <String>[],
    loadHistorySongs: (date) async => const <rust.SongDto>[],
    onOpenPlaylist: (_) {},
    initialTab: initialTab,
  ),
);

/// 段落的自然宽度(不裁字时应有的宽度): 用页面里同一份 span + 同一个 textScaler
/// 重新排一次, 与被约束后的实测宽度比 —— 被裁时实测宽度会更小。
void expectNotClipped(WidgetTester tester, String label) {
  final finder = find.text(label);
  expect(finder, findsOneWidget, reason: '$label 页签必须存在');
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final scaler = MediaQuery.textScalerOf(tester.element(finder));
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final natural = painter.width;
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(natural - 0.5),
    reason: '$label 被裁字: 实测 ${paragraph.size.width} < 自然宽 $natural',
  );
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '$label 段落溢出(maxLines 被截)',
  );
  // 三个页签都必须落在视口内(300dp 下总计 282dp, 不需要拖就能看全)
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(300.0));
}

void main() {
  testWidgets('300dp + 1.25 字号: 三个页签文本完整、可横向拖, 切换页签仍正常', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();

    // 页签仍是 TabBar 自己管(不是自写 chip 行): 指示器/联动都还在
    final tabBar = tester.widget<TabBar>(find.byType(TabBar));
    expect(tabBar.isScrollable, isTrue, reason: '必须是自然宽度(可横拖), 不能均分屏宽');
    expect(tabBar.tabAlignment, TabAlignment.start);

    for (final label in _labels) {
      expectNotClipped(tester, label);
    }

    // 横向拖一下不炸(内容不足一屏时 TabBar 不会滚, 但手势必须安全)
    await tester.drag(find.byType(TabBar), const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expectNotClipped(tester, _labels.last);

    // 切换页签: 点「推荐歌单」再点「历史日推」, 两页各自的空态都要出来
    await tester.tap(find.text('推荐歌单'));
    await tester.pumpAndSettle();
    expect(find.text('今天没有推荐歌单'), findsOneWidget);

    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();
    expect(find.textContaining('最近 5 次日推仅黑胶 VIP 可见'), findsOneWidget);
    // 组内联动没被打断: 页签文字全部还在
    for (final label in _labels) {
      expect(find.text(label), findsOneWidget);
    }
  });

  testWidgets('initialTab 可落到「历史日推」(B7 快捷动作复用同一页)', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1;
    tester.view.platformDispatcher.textScaleFactorTestValue = 1.25;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_page(initialTab: 2));
    await tester.pumpAndSettle();

    expect(find.textContaining('最近 5 次日推仅黑胶 VIP 可见'), findsOneWidget);
    // 默认 0 仍是「推荐歌曲」
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_page());
    await tester.pumpAndSettle();
    expect(find.text('今天没有推荐歌曲'), findsOneWidget);
  });
}
