import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/settings_sleep_timer_page.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/sleep_timer.dart';

/// 定时关闭(睡眠定时): 纯逻辑边界 + 设置页窄屏回归。
///
/// 逻辑层用假时钟推进时间(不会真的等 15 分钟), 到点动作只数次数 —— 真正的
/// "停播放 + 退出应用" 由 home_page 注入, 单测里绝不调平台 API。
void main() {
  /// 一次受控的计时环境: 假时钟 + 计数到点动作。
  ({SleepTimer timer, void Function(Duration) advance, int Function() fires})
  harness({SleepTimerMode mode = SleepTimerMode.immediate}) {
    var now = DateTime(2026, 11, 18, 23);
    var fires = 0;
    final timer = SleepTimer(now: () => now)..onExpire = () => fires++;
    timer.setMode(mode);
    return (
      timer: timer,
      advance: (Duration d) => now = now.add(d),
      fires: () => fires,
    );
  }

  group('SleepTimer 纯逻辑', () {
    test('立刻停: 到点触发一次且只一次', () {
      final h = harness();
      h.timer.start(duration: const Duration(minutes: 15));
      expect(h.timer.active, isTrue);
      h.timer.onPlaybackTick(playing: true);
      expect(h.fires(), 0);

      h.advance(const Duration(minutes: 15));
      h.timer.onPlaybackTick(playing: true);
      expect(h.fires(), 1);
      expect(h.timer.fired, isTrue);
      expect(h.timer.active, isFalse);

      // 后续心跳/曲末都不得再触发一次
      h.timer.onPlaybackTick(playing: true);
      h.timer.onTrackEnded();
      h.advance(const Duration(minutes: 5));
      h.timer.onPlaybackTick(playing: false);
      expect(h.fires(), 1);
    });

    test('播完这首: 到点仍在播不触发, 曲末才触发', () {
      final h = harness(mode: SleepTimerMode.finishCurrentSong);
      h.timer.start(duration: const Duration(minutes: 15));

      // 到点前就播完: 正常续播, 什么都不做
      h.advance(const Duration(minutes: 10));
      h.timer.onTrackEnded();
      expect(h.fires(), 0);

      h.advance(const Duration(minutes: 5));
      h.timer.onPlaybackTick(playing: true);
      expect(h.fires(), 0, reason: '到点时仍在播, 不能立刻停');
      expect(h.timer.pendingFinish, isTrue, reason: '应进入等本曲播完');

      h.timer.onTrackEnded();
      expect(h.fires(), 1);
      expect(h.timer.fired, isTrue);
    });

    test('播完这首: 到点时已暂停则直接触发', () {
      final h = harness(mode: SleepTimerMode.finishCurrentSong);
      h.timer.start(duration: const Duration(minutes: 30));
      h.advance(const Duration(minutes: 30));
      h.timer.onPlaybackTick(playing: false);
      expect(h.fires(), 1);
      expect(h.timer.pendingFinish, isFalse);
    });

    test('取消后到点不触发', () {
      final h = harness();
      h.timer.start(duration: const Duration(minutes: 15));
      h.advance(const Duration(minutes: 5));
      h.timer.cancel();
      expect(h.timer.active, isFalse);
      expect(h.timer.remaining, isNull);

      h.advance(const Duration(minutes: 30));
      h.timer.onPlaybackTick(playing: true);
      h.timer.onTrackEnded();
      expect(h.fires(), 0);
    });

    test('改档 = 重新计时(旧截止时间作废)', () {
      final h = harness();
      h.timer.start(duration: const Duration(minutes: 15));
      h.advance(const Duration(minutes: 10));
      expect(h.timer.remaining, const Duration(minutes: 5));

      h.timer.start(duration: const Duration(minutes: 30));
      expect(h.timer.remaining, const Duration(minutes: 30));

      // 原 15 分钟档的截止点已过, 但新档位还在计
      h.advance(const Duration(minutes: 6));
      h.timer.onPlaybackTick(playing: true);
      expect(h.fires(), 0);

      h.advance(const Duration(minutes: 24));
      h.timer.onPlaybackTick(playing: true);
      expect(h.fires(), 1);
    });

    test('已开启时切停法按改档重置(重新从当前档位计时)', () {
      final h = harness();
      h.timer.start(duration: const Duration(minutes: 60));
      h.advance(const Duration(minutes: 30));
      h.timer.setMode(SleepTimerMode.finishCurrentSong);
      expect(h.timer.mode, SleepTimerMode.finishCurrentSong);
      expect(h.timer.remaining, const Duration(minutes: 60));
    });

    test('剩余时间文案: 不足 1 小时 mm:ss, 超过 1 小时 h:mm:ss', () {
      expect(sleepTimerRemainingLabel(const Duration(minutes: 15)), '15:00');
      expect(sleepTimerRemainingLabel(const Duration(minutes: 90)), '1:30:00');
      expect(
        sleepTimerRemainingLabel(const Duration(minutes: 1, seconds: 3)),
        '01:03',
      );
      expect(sleepTimerRemainingLabel(const Duration(seconds: -5)), '00:00');
    });

    test('档位固定且从短到长', () {
      expect(kSleepTimerPresets, <int>[15, 30, 45, 60, 90]);
    });
  });

  group('SleepTimerPage', () {
    testWidgets('选档开始计时 / 取消 / 300dp+1.25 字号不溢出', (tester) async {
      tester.view.physicalSize = const Size(300, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var now = DateTime(2026, 11, 18, 23);
      final timer = SleepTimer(now: () => now);
      var fires = 0;
      timer.onExpire = () => fires++;

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.25)),
            child: child!,
          ),
          home: SleepTimerPage(timer: timer),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('未开启'), findsOneWidget);

      // 选档: 开始计时并显示剩余
      await tester.tap(find.byKey(const Key('sleepTimerPreset15')));
      await tester.pumpAndSettle();
      expect(timer.active, isTrue);
      expect(find.textContaining('还剩'), findsOneWidget);
      expect(find.textContaining('15:00'), findsOneWidget);

      // 剩余时间跟着假时钟走(页面靠状态机通知重建, 不自己起轮询)
      now = now.add(const Duration(minutes: 3));
      timer.onPlaybackTick(playing: true);
      await tester.pumpAndSettle();
      expect(find.textContaining('12:00'), findsOneWidget);

      // 取消
      await tester.tap(find.byKey(const Key('sleepTimerCancel')));
      await tester.pumpAndSettle();
      expect(timer.active, isFalse);
      expect(find.text('未开启'), findsOneWidget);
      expect(fires, 0);
    });

    testWidgets('设置页入口: 点「定时关闭」进入本页(全局状态机)', (tester) async {
      tester.view.physicalSize = const Size(1000, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // 全局单例可能被别的用例/上一个页面留着状态: 先清掉, 用例结束也清掉
      sleepTimer.cancel();
      addTearDown(sleepTimer.cancel);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SettingsView(info: null))),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('定时关闭'));
      await tester.pumpAndSettle();

      expect(find.byType(SleepTimerPage), findsOneWidget);
      expect(find.text('未开启'), findsOneWidget);
    });
  });
}
