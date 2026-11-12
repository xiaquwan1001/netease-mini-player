// 风格推荐配图窗格: 窄屏 300dp + 大字号的"结构级"回归.
//
// 背景: 配图窗格(_StyleTiles, 公开面 = RecommendView.loadStyles + CoverArt)
// 是排行榜区块内的横滑行, 每个 88dp 窗格 = 配图 + 单行名字.
// 现有 style_tiles_test 只测了"看得见/不溢出"两例, 这里补:
// 三档字号下可横滑 + 拖动无异常; 有/无配图混排时的计数; 名字单行省略号.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;

const _longName = '一个很长很长的曲风名字用来验证省略号';

Widget _recommend(List<rust.StyleTag> tags) => RecommendView(
  loggedIn: true,
  onPlaySongs: (_, _) {},
  onOpenPlaylist: (_) {},
  onOpenPodcast: (_) {},
  onHeartMode: () {},
  onOpenDaily: () {},
  loadDailySongs: () async => const [],
  loadDailyPlaylists: () async => const [],
  loadPodcasts: () async => const [],
  loadFm: () async => const [],
  loadStyles: () async => tags,
  loadNewSongs: () async => const [],
);

final _tags = const [
  rust.StyleTag(
    id: '1000',
    name: '流行',
    coverUrl: 'https://p6.music.126.net/obj/109951165924166690',
  ),
  rust.StyleTag(id: '1001', name: '爵士'),
  rust.StyleTag(id: '1002', name: _longName),
  rust.StyleTag(id: '1003', name: '电子'),
  rust.StyleTag(id: '1004', name: '民谣'),
];

/// 全页其它区块都给空 loader, 只有风格窗格有内容, 定位更稳.
Future<void> _pump(WidgetTester tester, {required double textScale}) async {
  tester.view.physicalSize = const Size(300, 2200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: _recommend(_tags)),
      ),
    ),
  );
  // CoverArt 的离线加载失败回退到占位, 等 settle 会一直等网络超时, 用固定 pump.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

/// 页面上所有横向滚动的 Scrollable(风格窗格那一行).
Iterable<ScrollableState> _horizontalScrollables(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .where(
      (s) =>
          s.widget.axisDirection == AxisDirection.left ||
          s.widget.axisDirection == AxisDirection.right,
    );

void main() {
  for (final scale in const [1.0, 1.25, 1.625]) {
    testWidgets('300dp 窄屏 × 字号 $scale: 无溢出, 风格窗格可横向滚动', (tester) async {
      await _pump(tester, textScale: scale);

      expect(tester.takeException(), isNull, reason: '300dp × $scale 全页不能溢出');
      expect(find.text('风格推荐'), findsOneWidget);

      final scrollables = _horizontalScrollables(tester).toList();
      expect(scrollables, isNotEmpty, reason: '风格窗格行应当是横向滚动');
      final before = scrollables.first.position.pixels;

      // 横向拖一把: 不抛异常且内容真的滚动了(电子排在第 4 块, 300dp 上看不见,
      // 从可见的第 2 块「爵士」拖)
      await tester.drag(find.text('爵士'), const Offset(-200, 0));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(
        _horizontalScrollables(tester).first.position.pixels,
        greaterThan(before),
        reason: '窄屏上窗格行应能横向滚到后面的风格',
      );
    });
  }

  testWidgets('有配图显示 CoverArt, 无配图退回钢琴图标(混排计数)', (tester) async {
    await _pump(tester, textScale: 1.0);

    // 风格窗格里: 1 个有 coverUrl 的标签 → 恰好 1 个带 url 的 CoverArt;
    // 其余 4 个无 coverUrl → 4 个钢琴占位.
    final covers = tester.widgetList<CoverArt>(find.byType(CoverArt)).toList();
    expect(
      covers.where((c) => c.url != null && c.url!.isNotEmpty).length,
      1,
      reason: '有配图的曲风用 CoverArt 渲染',
    );
    expect(
      find.byIcon(Icons.piano),
      findsNWidgets(4),
      reason: '没有配图的曲风退回同尺寸钢琴图标占位',
    );
  });

  testWidgets('窄屏下窗格名字单行 + 省略号截断', (tester) async {
    await _pump(tester, textScale: 1.625);

    final nameText = tester.widget<Text>(find.text(_longName).first);
    expect(nameText.maxLines, 1, reason: '窗格名字不能折行把窗格撑高');
    expect(
      nameText.overflow,
      TextOverflow.ellipsis,
      reason: '窄屏 + 大字号下超长曲风名要省略号截断',
    );
  });
}
