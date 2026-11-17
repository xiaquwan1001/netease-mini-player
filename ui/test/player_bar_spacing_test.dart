// 常驻播放条的横向口径: 窄屏(手机预算) / 宽屏(桌面窗口+平板)两档留白与控件间隔.
//
// 背景(2026-11-18 用户反馈「播放条控件挤在右下角, 间距不自然」): 同一份 Dart 代码
// 在手机(360dp)上紧凑排得下, 到 Linux 桌面窗口(默认 1280x720)上就变成左右留白仍
// 只有 4dp、六个控件零间隔贴成一坨压在窗口右下角, 与左边的歌名之间一大片空白.
// 根因是播放条只有「手机预算」一档排版, 没有宽度断点.
//
// 修法见 layout.dart「常驻播放条的横向口径」: 宽度 >= kPlayerBarRoomyWidth 时
// 左右留白改用 kPagePadding(12), 控件之间插入 kRowTitleGap(8); 窄屏保持原值
// (kPlayerBarEdgeInset = 4 + 零间隔), 否则 300dp 上信息行会被挤到 0.
//
// 断言口径:
//   · 宽屏: 左右留白都 >= kPagePadding, 相邻控件间隔全等 == kRowTitleGap,
//     左侧信息块与右侧控件之间留白 >= kRowTitleGap;
//   · 窄屏(300dp + 1.25 字号, 项目最严口径): 不溢出(无 RenderFlex overflow),
//     留白仍是手机预算的 kPlayerBarEdgeInset(没有偷偷变宽).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/api.dart' as rust;

PlayerBarData _data() => PlayerBarData(
  player: PlayerView(
    playing: true,
    positionMs: BigInt.from(30 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
  ),
  // 长歌名 + VIP: 让信息行在窄屏上真的会被挤(验证 ellipsis 而不是溢出)
  current: rust.SongDto(
    id: BigInt.one,
    name: '一首很长很长的歌名用来验证窄屏降级不溢出',
    artist: '某位名字也不短的艺人',
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
  onOpenDetail: () {},
  onToggleLike: () {},
  onCycleMode: () {},
  onOpenQueue: () {},
  onToggle: () {},
  onPrevious: () {},
  onNext: () {},
);

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(width, 240);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 240),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MiniPlayerBar(
              data: _data(),
              actions: _actions(),
              absorbBottomInset: false,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 播放条「信息行」(封面 + 歌名 + 控件)那一个 Row 的矩形: 它的左右边界就是
/// 播放条自己的横向留白之后的内容区(外层 Padding 的可见结果), 比量封面更准
/// (封面内部还有自己的 8dp 左内边距).
Rect _rowRect(WidgetTester tester) => tester.getRect(
  find
      .ancestor(of: find.byType(IconButton).first, matching: find.byType(Row))
      .first,
);

/// 播放条右侧控件组(红心/顺序/上一首/播放/下一首/队列)的点击区矩形, 按行内顺序.
List<Rect> _controlRects(WidgetTester tester) => [
  for (final e in tester.elementList(find.byType(IconButton)))
    tester.getRect(find.byWidget(e.widget)),
];

void main() {
  testWidgets('宽屏(1280): 左右留白按 kPagePadding, 控件间隔全等且不贴边', (tester) async {
    const width = 1280.0;
    await _pump(tester, width: width);

    final bar = tester.getRect(find.byType(MiniPlayerBar));
    final row = _rowRect(tester);
    final cover = tester.getRect(find.byType(CoverArt));
    final controls = _controlRects(tester);
    expect(controls.length, 6, reason: '播放条右侧控件数变了(红心/顺序/上一首/播放/下一首/队列)');

    // 1) 左右都不贴窗口边: 以前左右留白只有 4dp, 肉眼看就是压在右下角.
    expect(
      row.left - bar.left,
      moreOrLessEquals(kPagePadding, epsilon: 0.01),
      reason: '左侧留白没有按宽屏口径(kPagePadding)',
    );
    expect(
      bar.right - row.right,
      moreOrLessEquals(kPagePadding, epsilon: 0.01),
      reason: '右侧留白没有按宽屏口径(kPagePadding)',
    );

    // 2) 控件之间间距一致: 相邻间隔全等 == kRowTitleGap(以前是 0, 六个控件挤成一片).
    for (var i = 1; i < controls.length; i++) {
      expect(
        controls[i].left - controls[i - 1].right,
        moreOrLessEquals(kRowTitleGap, epsilon: 0.01),
        reason: '第 $i 个与第 ${i + 1} 个控件之间的间隔不是 kRowTitleGap',
      );
    }

    // 3) 两侧之间留白: 左侧信息块(封面)与右侧控件组之间 >= kRowTitleGap.
    expect(
      controls.first.left - cover.right,
      greaterThanOrEqualTo(kRowTitleGap),
      reason: '左侧信息与右侧控件之间没有留白',
    );

    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏(300dp + 1.25 字号): 不溢出, 留白仍是手机预算', (tester) async {
    const width = 300.0;
    await _pump(tester, width: width, textScale: 1.25);

    final bar = tester.getRect(find.byType(MiniPlayerBar));
    final row = _rowRect(tester);
    final controls = _controlRects(tester);

    // 手机预算不变: 左右留白仍是 4(改成 12 会把信息行挤到 0)
    expect(
      row.left - bar.left,
      moreOrLessEquals(kPlayerBarEdgeInset, epsilon: 0.01),
      reason: '窄屏留白被改宽了(300dp 上信息行会归零)',
    );
    expect(
      bar.right - row.right,
      moreOrLessEquals(kPlayerBarEdgeInset, epsilon: 0.01),
      reason: '窄屏右留白被改宽了(300dp 上信息行会归零)',
    );
    // 窄屏不加额外间隔: 控件必须仍然贴排, 否则整行放不下
    for (var i = 1; i < controls.length; i++) {
      expect(
        controls[i].left - controls[i - 1].right,
        lessThanOrEqualTo(kPlayerBarEdgeInset),
        reason: '窄屏下控件之间被塞了额外间隔, 整行会放不下',
      );
    }
    // 行内不溢出: 最后一个控件仍在播放条内(300dp 全宽的窄屏上不允许压到边界外)
    expect(controls.last.right, lessThanOrEqualTo(bar.right));
    expect(tester.takeException(), isNull, reason: '窄屏 + 1.25 字号下播放条行内溢出');
  });
}
