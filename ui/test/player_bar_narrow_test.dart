// 常驻播放条(PlayerBarHost)的真实组件: 窄屏 300dp + 大字号的"结构级"回归.
//
// 背景: 播放条已从 main.dart 的私有类搬到 ui/lib/src/player_bar.dart 的公开
// [MiniPlayerBar], 数据/回调改由 [playerBarData]/[playerBarActions] 两个槽投递
// (不再投递整棵 Widget). 这里用真实组件 + 真实数据契约做断言, 不用替身.
//
// 覆盖 player_bar_host_test(3 例)与 player_bar_data_test(数据相等性)没覆盖的组合:
// 窄屏 x 1.0/1.25/1.625 不溢出; 播放条在内容区"之下"(Column 而非 Overlay 盖上去);
// 键盘弹出时播放条不占任何内容高度.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/adaptive_text_row.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/rust/api.dart' as rust;

PlayerBarData _data() => PlayerBarData(
  player: PlayerView(
    playing: true,
    positionMs: BigInt.from(30 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
  ),
  current: rust.SongDto(
    id: BigInt.one,
    name: '一首很长很长的歌名用来验证窄屏降级不溢出',
    artist: '某位名字也不短的歌手',
    artistId: BigInt.one,
    album: '专辑',
    albumId: BigInt.one,
    coverUrl: null,
    durationMs: BigInt.from(200 * 1000),
    fee: 0,
    vip: true,
    paid: false,
    playable: true,
  ),
  liked: false,
  queueIndex: 3,
  queueLength: 12,
  dragMax: null,
  dragMs: null,
);

PlayerBarActions _actions() => PlayerBarActions(
  onSeekStart: (_) {},
  onSeekChanging: (_) {},
  onSeekEnd: (_) {},
  onToggleLyrics: () {},
  onOpenAlbum: () {},
  onToggleLike: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
  onToggle: () {},
  onNext: () {},
);

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
      body: SizedBox.expand(
        key: contentKey,
        child: const ColoredBox(color: Colors.teal),
      ),
    ),
  );
}

void _pumpBar() {
  playerBarData.value = _data();
  playerBarActions.value = _actions();
}

void main() {
  tearDown(() {
    playerBarSlot.value = null;
    playerBarData.value = null;
    playerBarActions.value = null;
  });

  for (final scale in const [1.0, 1.25, 1.625]) {
    testWidgets('300dp 窄屏 × 字号 $scale: 播放条不溢出不抛异常', (tester) async {
      tester.view.physicalSize = const Size(300, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      _pumpBar();
      await tester.pumpWidget(_app(textScale: scale));
      // 标题行的跑马灯(MarqueeText)永远在动画, pumpAndSettle 会超时, 用固定帧.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        tester.takeException(),
        isNull,
        reason: '300dp × $scale 下播放条(进度条/封面/标题/4 按钮)不能溢出',
      );
      expect(find.byType(MiniPlayerBar), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.byType(CoverArt), findsOneWidget);
      expect(find.byType(AdaptiveTextRow), findsOneWidget);
      // 每个操作按钮都有 tooltip(→ Semantics label), 窄屏下也不能被裁掉
      expect(find.byTooltip('喜欢'), findsOneWidget);
      // 数据里 playing=true, 播放键的 tooltip 就是「暂停」(状态文案回归)
      expect(find.byTooltip('暂停'), findsOneWidget);
      // 上一首按钮已移除; 原位置换成播放顺序, 行尾加队列入口
      expect(find.byTooltip('上一首'), findsNothing);
      expect(find.byTooltip('播放顺序: 列表循环'), findsOneWidget);
      expect(find.byTooltip('播放队列'), findsOneWidget);
      expect(find.byTooltip('下一首'), findsOneWidget);
    });
  }

  testWidgets('300dp 窄屏: 播放条位于内容区之下(不是覆盖层)', (tester) async {
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const contentKey = Key('content');
    _pumpBar();
    await tester.pumpWidget(_app(textScale: 1.25, contentKey: contentKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final contentBottom = tester.getBottomLeft(find.byKey(contentKey)).dy;
    final barTop = tester.getTopLeft(find.byType(MiniPlayerBar)).dy;
    expect(
      barTop,
      greaterThanOrEqualTo(contentBottom - 0.5),
      reason: '播放条由 Column 排在内容区之下, 不能盖在内容上面',
    );
    expect(contentBottom, lessThanOrEqualTo(800));
  });

  testWidgets('键盘弹出: 播放条占位高度为 0(内容区拿满全屏高)', (tester) async {
    tester.view.physicalSize = const Size(300, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const contentKey = Key('content');
    _pumpBar();
    await tester.pumpWidget(
      _app(keyboardInset: 320, textScale: 1.25, contentKey: contentKey),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(MiniPlayerBar), findsNothing, reason: '键盘弹出时播放条整体让位');
    final contentSize = tester.getSize(find.byKey(contentKey));
    expect(contentSize.height, 800, reason: '播放条隐藏后不应再占任何内容高度');
  });
}
