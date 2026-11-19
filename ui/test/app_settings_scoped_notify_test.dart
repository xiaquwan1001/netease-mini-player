// §12.6 第二步的守门用例: AppSettings 的**不可变快照** + **按域 diff 通知**。
//
// 改造前的痛点: 单例字段全是可变 public 成员, 只能整份 notifyListeners(),
// 于是"拖动音量滑块"会重建根 MaterialApp(主题/字号)与所有订阅者。
// 这里把新的契约钉住:
//   ① 单域变更只通知该域的订阅者(其它域 0 次), 全体 addListener 仍收到 1 次;
//   ② 高频改音量(20 次)一次都不惊动外观/交互域;
//   ③ 已经拿到手的旧快照不随后续更新改变(含 interactions 的 copy-on-write);
//   ④ AppSettingsScopedBuilder 只在自己的域变化时重建。
// codec 往返/字节稳定仍由 app_settings_codec_roundtrip_test.dart 守着(未改动)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';

void main() {
  final settings = AppSettings.instance;

  late bool oledDark;
  late double volumeGainDb;
  late double textScale;

  setUp(() {
    oledDark = settings.oledDark;
    volumeGainDb = settings.volumeGainDb;
    textScale = settings.textScale;
  });

  tearDown(() {
    settings.oledDark = oledDark;
    settings.volumeGainDb = volumeGainDb;
    settings.textScale = textScale;
  });

  /// 注册一组计数器(外观/播放/交互三个域 + 全体), 用完自动摘掉。
  ({
    int Function() appearance,
    int Function() playback,
    int Function() interactions,
    int Function() global,
    int Function() count,
  })
  watch() {
    var appearance = 0;
    var playback = 0;
    var interactions = 0;
    var global = 0;
    void onAppearance() => appearance++;
    void onPlayback() => playback++;
    void onInteractions() => interactions++;
    void onGlobal() => global++;
    settings.addScopedListener(const {
      AppSettingsDomain.appearance,
    }, onAppearance);
    settings.addScopedListener(const {AppSettingsDomain.playback}, onPlayback);
    settings.addScopedListener(const {
      AppSettingsDomain.interactions,
    }, onInteractions);
    settings.addListener(onGlobal);
    addTearDown(() {
      settings.removeScopedListener(onAppearance);
      settings.removeScopedListener(onPlayback);
      settings.removeScopedListener(onInteractions);
      settings.removeListener(onGlobal);
    });
    int pick(int a, int p, int i) => a + p + i;
    return (
      appearance: () => appearance,
      playback: () => playback,
      interactions: () => interactions,
      global: () => global,
      count: () => pick(appearance, playback, interactions),
    );
  }

  test('单域变更只通知该域的订阅者(其它域 0 次), 全体监听者仍收到', () async {
    final c = watch();
    await settings.update(oledDark: !oledDark);

    expect(c.appearance(), 1, reason: '外观域必须被通知');
    expect(c.playback(), 0);
    expect(c.interactions(), 0);
    expect(c.global(), 1, reason: '全体 addListener 的旧契约不变');
  });

  test('高频改音量: 播放域 20 次, 外观/交互域 0 次', () async {
    final c = watch();
    for (var i = 1; i <= 20; i++) {
      await settings.update(volumeGainDb: -i.toDouble());
    }

    expect(c.playback(), 20);
    expect(c.appearance(), 0, reason: '音量拖动不该重建主题/字号');
    expect(c.interactions(), 0, reason: '音量拖动不该惊动「我的」页排序');
    expect(c.global(), 20);
  });

  test('空写(值与原来相同)不产生通知', () async {
    final c = watch();
    await settings.update(
      volumeGainDb: settings.volumeGainDb,
      oledDark: oledDark,
    );
    expect(c.count(), 0);
    expect(c.global(), 0);
  });

  test('交互记录只通知交互域; 老快照的 interactions 不跟着变', () async {
    final c = watch();
    final before = settings.snapshot;
    final id = BigInt.from(990001);

    await settings.touchInteraction('album', id, nowMs: 42);

    expect(c.interactions(), 1);
    expect(c.appearance(), 0);
    expect(c.playback(), 0);
    expect(settings.lastInteractionMs('album', id), 42);
    expect(
      before.interactions.containsKey('album:990001'),
      isFalse,
      reason: '旧快照必须是不可变的(记录走 copy-on-write)',
    );
  });

  test('旧快照拿到后不随更新改变', () async {
    final before = settings.snapshot;
    final oldScale = before.textScale;
    await settings.update(textScale: oldScale == 1.05 ? 1.10 : 1.05);

    expect(before.textScale, oldScale);
    expect(settings.snapshot.textScale, isNot(oldScale));
    expect(identical(before, settings.snapshot), isFalse);
  });

  testWidgets('AppSettingsScopedBuilder 只在自身域变化时重建', (tester) async {
    var builds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppSettingsScopedBuilder(
          domains: const {AppSettingsDomain.appearance},
          builder: (_) {
            builds++;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(builds, 1);

    await settings.update(volumeGainDb: -3.0);
    await tester.pump();
    expect(builds, 1, reason: '播放域变化不该重建外观域的订阅者');

    await settings.update(oledDark: !oledDark);
    await tester.pump();
    expect(builds, 2);
  });
}
