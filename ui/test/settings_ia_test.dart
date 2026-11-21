// 设置页 IA 重组(2026-11: 「设置页面内容很乱, 按主题划分二级页面」)的回归。
//
// 两条口径:
// 1) **可达**: 设置首页的 7 个主题入口都能进到对应二级页(账号走宿主回调);
// 2) **写回原键名**: 搬动只改位置, 不改键名/默认值/持久化格式 —— 抽查四种
//    不同形态的控件(分段选择 / 开关 / 弹层选择 / 下拉框), 每种都断言写回的是
//    原来那个 AppSettings 字段。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/settings_audio_page.dart';
import 'package:minincm/src/settings_diagnostics_page.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/settings_view.dart';

rust.InitInfo info({bool loggedIn = true}) => rust.InitInfo(
  dataDir: '/tmp/minincm',
  deviceId: 'dev-1',
  loggedIn: loggedIn,
  vip: false,
  providers: const [],
);

/// 设置首页与各二级页都是长列表: 给一个高视口让所有行都参与布局。
void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3200);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Future<void> pumpHome(WidgetTester tester, {VoidCallback? onAccounts}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SettingsView(info: info(), onOpenAccounts: onAccounts),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('设置首页: 每个主题入口都可达', () {
    testWidgets('账号与同步走宿主回调(账号页由宿主注入)', (tester) async {
      big(tester);
      var opened = 0;
      await pumpHome(tester, onAccounts: () => opened++);
      await tester.tap(find.text('账号与同步'));
      expect(opened, 1);
    });

    for (final title in const [
      '播放与音质',
      '外观与布局',
      '通知与系统',
      '插件与音源',
      '数据与诊断',
      '关于',
    ]) {
      testWidgets('$title: 点入口压入一个二级页且能返回', (tester) async {
        big(tester);
        await pumpHome(tester);
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
        // 二级页 = 新的路由页(AppBar 上带返回键)
        expect(find.byType(BackButton), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text('设置'), findsOneWidget, reason: '返回后回到设置首页');
      });
    }
  });

  group('关键开关写回原键名(搬动不改语义)', () {
    final settings = AppSettings.instance;
    late ThemeMode themeMode;
    late bool oledDark;
    late int coverRows;
    late bool clearSearch;
    late bool skipVip;
    late UpdateCheckInterval updateInterval;
    late String audioLevel;

    setUp(() {
      themeMode = settings.themeMode;
      oledDark = settings.oledDark;
      coverRows = settings.coverRows;
      clearSearch = settings.clearSearchOnTabSwitch;
      skipVip = settings.skipVipSongs;
      updateInterval = settings.updateCheckInterval;
      audioLevel = settings.audioLevel;
    });

    tearDown(() {
      settings.update(
        themeMode: themeMode,
        oledDark: oledDark,
        coverRows: coverRows,
        clearSearchOnTabSwitch: clearSearch,
        skipVipSongs: skipVip,
        updateCheckInterval: updateInterval,
        audioLevel: audioLevel,
      );
    });

    testWidgets('外观与布局: 分段选择写 themeMode/coverRows, 开关写 oledDark', (
      tester,
    ) async {
      big(tester);
      await settings.update(themeMode: ThemeMode.light, coverRows: 1);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AppearanceSettingsPage())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(settings.themeMode, ThemeMode.dark);

      await tester.tap(find.text('纯黑 (OLED)'));
      await tester.pumpAndSettle();
      expect(settings.oledDark, isTrue);

      await tester.tap(find.text('两排'));
      await tester.pumpAndSettle();
      expect(settings.coverRows, 2);
    });

    testWidgets('通知与系统: 开关写 clearSearchOnTabSwitch, 弹层写 updateCheckInterval', (
      tester,
    ) async {
      big(tester);
      await settings.update(
        clearSearchOnTabSwitch: true,
        updateCheckInterval: UpdateCheckInterval.daily,
      );
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SystemSettingsPage())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('切到搜索时清空上次结果'));
      await tester.pumpAndSettle();
      expect(settings.clearSearchOnTabSwitch, isFalse);

      await tester.tap(find.text('自动检查更新'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('每周'));
      await tester.pumpAndSettle();
      expect(settings.updateCheckInterval, UpdateCheckInterval.weekly);
    });

    testWidgets('播放与音质: 开关写 skipVipSongs, 下拉框写 audioLevel', (tester) async {
      big(tester);
      await settings.update(skipVipSongs: false);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: AudioSettingsPage())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('播放跳过 VIP 歌曲'));
      await tester.pumpAndSettle();
      expect(settings.skipVipSongs, isTrue);

      // 取链音质(原设置首页的 DropdownButton)现在在本页「音质」段
      final other = AppSettings.audioLevels.keys.firstWhere(
        (k) => k != settings.audioLevel,
      );
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppSettings.audioLevels[other]!).last);
      await tester.pumpAndSettle();
      expect(settings.audioLevel, other);
    });

    testWidgets('数据与诊断: 日推缓存行在这里(键名 dailyCacheDays 未改)', (tester) async {
      big(tester);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: DiagnosticsPage())),
      );
      await tester.pumpAndSettle();
      expect(find.text('每日推荐缓存'), findsOneWidget);
      final dropdown = tester.widget<DropdownButton<int>>(
        find.byType(DropdownButton<int>),
      );
      expect(dropdown.value, settings.dailyCacheDays);
    });
  });
}
