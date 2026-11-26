// 播放条音量入口(2026-11-26 用户需求: 桌面/平板等宽屏设备在播放条上调音量)。
//
// 锁三件事:
//   · 只在宽档出现(窄 360 / 中 700 零变化), 且挂在控件行最右端;
//   · 它改的就是 AppSettings.volumeGainDb —— 与设置页「精细音量」同一份状态,
//     拖完 `settings.volumeGainDb` 真的变; 外部 update() 后图标也跟着变;
//   · 静音(-40 dB)/ 恢复(回 0 dB)语义。
//
// 一律用固定 pump(不用 pumpAndSettle): 播放条在宿主里常驻, settle 会挂在
// 常驻动画/周期重建上。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/layout.dart';
import 'package:minincm/src/player_bar.dart';
import 'package:minincm/src/player_volume_button.dart';
import 'package:minincm/src/playback.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

PlayerBarData _data() => PlayerBarData(
  player: PlayerView(
    playing: true,
    positionMs: BigInt.from(30 * 1000),
    durationMs: BigInt.from(200 * 1000),
    volume: 1.0,
  ),
  current: rust.SongDto(
    id: BigInt.one,
    name: '歌名甲',
    artist: '艺人乙',
    artistId: BigInt.one,
    album: '专辑丙',
    albumId: BigInt.one,
    coverUrl: null,
    durationMs: BigInt.from(200 * 1000),
    fee: 0,
    vip: false,
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
              desktopPlatformOverride: true,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// 点开面板。菜单开合有动画, 这里用两段固定 pump 走到位(不 pumpAndSettle)。
Future<void> _openPanel(WidgetTester tester) async {
  await tester.tap(find.byKey(PlayerVolumeButton.buttonKey));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Slider _panelSlider(WidgetTester tester) =>
    tester.widget<Slider>(find.byKey(PlayerVolumeButton.sliderKey));

void main() {
  final settings = AppSettings.instance;
  late double savedGain;

  setUp(() {
    savedGain = settings.volumeGainDb;
    settings.volumeGainDb = 0.0;
  });

  tearDown(() {
    // 存旧值并恢复: AppSettings 是进程单例, 用例之间会串。
    settings.volumeGainDb = savedGain;
    settings.notifyListeners();
  });

  group('档位: 只有宽档出现', () {
    for (final width in const [1200.0, 900.0]) {
      testWidgets('宽档($width): 出现且在最右端', (tester) async {
        expect(layoutTierFor(width), LayoutTier.wide);
        await _pump(tester, width: width);

        final button = find.byKey(PlayerVolumeButton.buttonKey);
        expect(button, findsOneWidget);
        expect(find.byType(PlayerVolumeButton), findsOneWidget);
        // 最右端: 它的右缘就是内容区右边界(bar 右缘 - kPagePadding)
        final bar = tester.getRect(find.byType(MiniPlayerBar));
        expect(
          bar.right - tester.getRect(button).right,
          moreOrLessEquals(kPagePadding, epsilon: 0.01),
        );
        expect(tester.takeException(), isNull);
      });
    }

    for (final width in const [360.0, 700.0]) {
      testWidgets('窄/中档($width): 不出现, 排版数字不变', (tester) async {
        expect(layoutTierFor(width), isNot(LayoutTier.wide));
        await _pump(tester, width: width);

        expect(find.byType(PlayerVolumeButton), findsNothing);
        expect(find.byKey(PlayerVolumeButton.buttonKey), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('最紧的宽档(900)+ 1.25 字号: 不溢出', (tester) async {
      await _pump(tester, width: 900, textScale: 1.25);

      expect(find.byType(PlayerVolumeButton), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '900dp × 1.25 字号下行内溢出');
    });
  });

  group('与设置页同一个值', () {
    testWidgets('默认 0 dB: 满格图标 + 「不变」', (tester) async {
      await _pump(tester, width: 1200);

      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      expect(find.byTooltip('音量 不变'), findsOneWidget);

      await _openPanel(tester);
      expect(_panelSlider(tester).value, 0.0);
      // 面板与设置页共用一份文案口径: 0 dB 显示「不变」
      expect(find.text('不变'), findsOneWidget);
    });

    testWidgets('拖滑条: 真的写回 AppSettings.volumeGainDb', (tester) async {
      await _pump(tester, width: 1200);
      await _openPanel(tester);

      _panelSlider(tester).onChanged!(-12.5);
      await tester.pump();

      expect(settings.volumeGainDb, -12.5);
      // 设置页读同一份 → 那边会显示 -12.5 dB; 这里验播放条自己跟上
      expect(find.text('-12.5 dB'), findsOneWidget);
      expect(_panelSlider(tester).value, -12.5);
      expect(find.byIcon(Icons.volume_down), findsOneWidget);
    });

    testWidgets('外部 update(volumeGainDb: -20) 后播放条图标跟着变', (tester) async {
      await _pump(tester, width: 1200);
      expect(find.byIcon(Icons.volume_up), findsOneWidget);

      // 模拟「设置页拖了滑条」: 只有 AppSettings 变了, 播放条没被重建过
      await settings.update(volumeGainDb: -20);
      await tester.pump();

      expect(find.byIcon(Icons.volume_down), findsOneWidget);
      expect(find.byIcon(Icons.volume_up), findsNothing);
      expect(find.byTooltip('音量 -20.0 dB'), findsOneWidget);
    });

    testWidgets('面板开着时外部改动, 滑条位置也跟上(双向)', (tester) async {
      await _pump(tester, width: 1200);
      await _openPanel(tester);
      expect(_panelSlider(tester).value, 0.0);

      await settings.update(volumeGainDb: -30);
      await tester.pump();

      expect(_panelSlider(tester).value, -30.0);
      expect(find.text('-30.0 dB'), findsOneWidget);
    });
  });

  group('静音 / 恢复', () {
    testWidgets('静音 = -40 dB, 恢复 = 回 0 dB(不变)', (tester) async {
      settings.volumeGainDb = -12.5;
      await _pump(tester, width: 1200);
      expect(find.byIcon(Icons.volume_down), findsOneWidget);

      await _openPanel(tester);
      expect(find.text('静音'), findsOneWidget);

      await tester.tap(find.byKey(PlayerVolumeButton.muteToggleKey));
      await tester.pump();
      expect(settings.volumeGainDb, -40.0);
      expect(find.byIcon(Icons.volume_off), findsOneWidget);
      expect(_panelSlider(tester).value, -40.0);
      // 面板不关: 静音后还能直接拖回来
      expect(find.text('恢复'), findsOneWidget);

      await tester.tap(find.byKey(PlayerVolumeButton.muteToggleKey));
      await tester.pump();
      expect(settings.volumeGainDb, 0.0, reason: '恢复固定回 0 dB(「不变」)');
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      expect(find.text('静音'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已在 -40: 入口一开始就是 volume_off + 「恢复」', (tester) async {
      settings.volumeGainDb = -40.0;
      await _pump(tester, width: 1200);

      expect(find.byIcon(Icons.volume_off), findsOneWidget);
      expect(find.byTooltip('音量 -40.0 dB'), findsOneWidget);

      await _openPanel(tester);
      expect(find.text('恢复'), findsOneWidget);
    });
  });
}
