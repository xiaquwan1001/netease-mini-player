// 播放条的「播放顺序」按钮: 引导态(私人FM/心动模式)换成专属图标 (2026-11-19 反馈 5/6).
//
// 用户口径: 播放模式与心动模式/私人FM 分开 —— 引导态下这个按钮的语义是
// 「退出引导回到列表循环」, 图标必须说明当前在哪个引导态:
//   · 普通态: 按 PlayMode 显示(列表循环/单曲循环/顺序播放/随机播放);
//   · 心动模式: 火焰(local_fire_department), 与推荐页入口同图;
//   · 私人FM: 广播(radio), 与推荐页「私人FM」卡片同图。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/queue.dart';

PlayerBarData _data({
  PlayMode mode = PlayMode.repeatAll,
  bool heartActive = false,
  bool fmActive = false,
}) => PlayerBarData(
  player: PlayerView(
    trackId: null,
    playing: false,
    positionMs: BigInt.zero,
    durationMs: BigInt.zero,
    volume: 1.0,
  ),
  current: null,
  liked: false,
  queueIndex: 1,
  queueLength: 1,
  dragMax: null,
  dragMs: null,
  mode: mode,
  heartActive: heartActive,
  fmActive: fmActive,
);

Widget _host(PlayerBarData data, {VoidCallback? onCycleMode}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.bottomCenter,
      child: MiniPlayerBar(
        data: data,
        absorbBottomInset: false,
        actions: PlayerBarActions(
          onSeekStart: (_) {},
          onSeekChanging: (_) {},
          onSeekEnd: (_) {},
          onToggleLyrics: () {},
          onOpenDetail: () {},
          onToggleLike: () {},
          onToggle: () {},
          onPrevious: () {},
          onNext: () {},
          onCycleMode: onCycleMode ?? () {},
          onOpenQueue: () {},
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('普通态按 PlayMode 换图标与文案', (tester) async {
    await tester.pumpWidget(_host(_data()));
    expect(find.byIcon(Icons.repeat), findsOneWidget);
    expect(find.byTooltip('播放顺序: 列表循环'), findsOneWidget);

    await tester.pumpWidget(_host(_data(mode: PlayMode.shuffle)));
    expect(find.byIcon(Icons.shuffle), findsOneWidget);
    expect(find.byTooltip('播放顺序: 随机播放'), findsOneWidget);
  });

  testWidgets('心动模式引导态: 火焰图标 + 「点击返回列表循环」', (tester) async {
    await tester.pumpWidget(_host(_data(heartActive: true)));
    expect(find.byIcon(Icons.local_fire_department), findsOneWidget);
    expect(find.byTooltip('心动模式(点击返回列表循环)'), findsOneWidget);
    expect(find.byIcon(Icons.repeat), findsNothing, reason: '引导态不再显示播放顺序图标');
  });

  testWidgets('私人FM 引导态: 广播图标 + 「点击返回列表循环」', (tester) async {
    await tester.pumpWidget(_host(_data(fmActive: true)));
    expect(find.byIcon(Icons.radio), findsOneWidget);
    expect(find.byTooltip('私人FM(点击返回列表循环)'), findsOneWidget);
    expect(find.byIcon(Icons.local_fire_department), findsNothing);
  });

  testWidgets('fm 与 heart 同时为真时 FM 优先(与 notificationModeIcon 同口径)', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_data(heartActive: true, fmActive: true)));
    expect(find.byIcon(Icons.radio), findsOneWidget);
    expect(find.byIcon(Icons.local_fire_department), findsNothing);
  });

  testWidgets('引导态下点按钮走的是同一个 onCycleMode(退出引导 = 回列表循环)', (tester) async {
    var cycles = 0;
    await tester.pumpWidget(
      _host(_data(fmActive: true), onCycleMode: () => cycles += 1),
    );
    await tester.tap(find.byTooltip('私人FM(点击返回列表循环)'));
    expect(cycles, 1);
  });
}
