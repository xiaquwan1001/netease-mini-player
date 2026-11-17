// §12.6 的守门用例: settings.json 的**键面**与**全字段往返**。
//
// 为什么需要它: AppSettings 是单一可变单例, 「加一个设置项」要同时改 5 处
// (字段 / app_settings_codec.dart 的某个 _apply* / _toJson / update() 参数 / 本文件)。
// 历史上真实踩过的两个坑都是漏改其中一处:
//   · 只写不读 ⇒ 用户「字号没有记忆」(重启回默认);
//   · 只读不写 ⇒ 改完当场生效、重启丢。
// 这里用两条断言把它们变成机械可查:
//   ① 落盘的 key 集合必须**精确等于**期望表(多/少都红);
//   ② 每个字段设成非默认值 → 落盘 → 字段复位 → load() 读回 → 逐字段等值。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/theme.dart';

/// settings.json 的键面(顺序无关)。加字段时**必须**同时改这里 —— 这是刻意的门槛。
const expectedKeys = <String>{
  // 外观
  'themeMode',
  'accent',
  'textScale',
  'coverRows',
  'gridColumns',
  'coverQuality',
  'oledDark',
  // 播放/音质
  'audioLevel',
  'skipVipSongs',
  'volumeGainDb',
  'loudnessNormalize',
  'loudnessTargetLufs',
  'loudnessDynamic',
  'eqProfileName',
  'eqProfileText',
  'fadeMs',
  'hardwareDecode',
  'streamCache',
  'cacheLimitMb',
  'lyricTranslation',
  'lyricSourcePreference',
  'schemaVersion',
  // 搜索/列表
  'clearSearchOnTabSwitch',
  'showHotSearch',
  'dailyCacheDays',
  'librarySearchPlayAction',
  // 平台/窗口
  'closeBehavior',
  // 自动更新
  'updateCheckInterval',
  'lastUpdateCheckMs',
  'skippedUpdateVersion',
  // 诊断
  'anonymousDebug',
  // 交互记录
  'interactions',
};

/// 把单例恢复到"未改动"的形状, 避免用例之间互相污染(同一文件的用例共享单例)。
void resetToDefaults() {
  final s = AppSettings.instance;
  s.themeMode = ThemeMode.system;
  s.accent = AccentPalette.neteaseRed;
  s.textScale = 1.0;
  s.audioLevel = 'exhigh';
  s.coverRows = 1;
  s.gridColumns = 3;
  s.clearSearchOnTabSwitch = true;
  s.showHotSearch = true;
  s.skipVipSongs = false;
  s.dailyCacheDays = 7;
  s.anonymousDebug = false;
  s.coverQuality = CoverQuality.standard;
  s.oledDark = false;
  s.volumeGainDb = 0.0;
  s.loudnessNormalize = false;
  s.loudnessTargetLufs = -16.0;
  s.loudnessDynamic = false;
  s.eqProfileName = null;
  s.eqProfileText = null;
  s.fadeMs = 0;
  s.hardwareDecode = true;
  s.streamCache = true;
  s.cacheLimitMb = 512;
  s.lyricTranslation = true;
  s.lyricSourcePreference = 'amll';
  s.closeBehavior = CloseBehavior.quit;
  s.librarySearchPlayAction = LibrarySearchPlayAction.fullList;
  s.updateCheckInterval = UpdateCheckInterval.daily;
  s.lastUpdateCheckMs = null;
  s.skippedUpdateVersion = null;
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ncm-settings-codec');
    resetToDefaults();
    // 先把 _file 指到临时目录(没有文件 ⇒ 保持默认值)
    await AppSettings.instance.load(dir.path);
    resetToDefaults();
  });

  tearDown(() async {
    resetToDefaults();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('落盘的 key 面 = 期望表(加/删字段必须同步这里的表)', () async {
    final s = AppSettings.instance;
    // 无参 update() 就是"按当前内存值整份落盘"
    await s.update();

    final raw = jsonDecode(
      File('${dir.path}/settings.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(
      raw.keys.toSet(),
      expectedKeys,
      reason: 'settings.json 的 key 面变了: 少了 redis 不回来的字段, 多了没人读的字段',
    );
  });

  test('全字段往返: 写出去的值, load() 必须原样读回', () async {
    final s = AppSettings.instance;
    // 每一项都设成**非默认**值: 这样"读了但没生效"会被断言抓到。
    s.themeMode = ThemeMode.dark;
    s.accent = AccentPalette.pink;
    s.textScale = 1.25;
    s.audioLevel = 'lossless';
    s.coverRows = 2;
    s.gridColumns = 4;
    s.clearSearchOnTabSwitch = false;
    s.showHotSearch = false;
    s.skipVipSongs = true;
    s.dailyCacheDays = 30;
    s.anonymousDebug = true;
    s.coverQuality = CoverQuality.ultra;
    s.oledDark = true;
    s.volumeGainDb = -7.5;
    s.loudnessNormalize = true;
    s.loudnessTargetLufs = -14.0;
    s.loudnessDynamic = true;
    s.eqProfileName = 'Sennheiser HD600';
    s.eqProfileText =
        'Preamp: -6.0 dB\nFilter 1: ON PK Fc 100 Hz Gain 3.0 dB Q 1.0';
    s.fadeMs = 500;
    s.hardwareDecode = false;
    s.streamCache = false;
    s.cacheLimitMb = 1024;
    s.lyricTranslation = false;
    s.lyricSourcePreference = 'netease';
    s.closeBehavior = CloseBehavior.minimizeToTray;
    s.librarySearchPlayAction = LibrarySearchPlayAction.appendCurrent;
    s.updateCheckInterval = UpdateCheckInterval.weekly;
    s.lastUpdateCheckMs = 1700000000000;
    s.skippedUpdateVersion = 'v9.9.9';
    await s.touchInteraction('album', BigInt.from(42), nowMs: 1700000000001);

    await s.update();
    final encoded = File('${dir.path}/settings.json').readAsStringSync();

    // 复位到默认值再读回: 任何"读了但没赋值"的字段都会停在默认值上被断言抓住。
    s.eqProfileName = null;
    s.eqProfileText = null;
    await s.load(dir.path);

    expect(s.themeMode, ThemeMode.dark);
    expect(s.accent, AccentPalette.pink);
    expect(s.textScale, 1.25);
    expect(s.audioLevel, 'lossless');
    expect(s.coverRows, 2);
    expect(s.gridColumns, 4);
    expect(s.clearSearchOnTabSwitch, isFalse);
    expect(s.showHotSearch, isFalse);
    expect(s.skipVipSongs, isTrue);
    expect(s.dailyCacheDays, 30);
    expect(s.anonymousDebug, isTrue);
    expect(s.coverQuality, CoverQuality.ultra);
    expect(s.oledDark, isTrue);
    expect(s.volumeGainDb, -7.5);
    expect(s.loudnessNormalize, isTrue);
    expect(s.loudnessTargetLufs, -14.0);
    expect(s.loudnessDynamic, isTrue);
    expect(s.eqProfileName, 'Sennheiser HD600');
    expect(s.eqProfileText, contains('Filter 1: ON PK'));
    expect(s.fadeMs, 500);
    expect(s.hardwareDecode, isFalse);
    expect(s.streamCache, isFalse);
    expect(s.cacheLimitMb, 1024);
    expect(s.lyricTranslation, isFalse);
    expect(s.lyricSourcePreference, 'netease');
    expect(s.closeBehavior, CloseBehavior.minimizeToTray);
    expect(s.librarySearchPlayAction, LibrarySearchPlayAction.appendCurrent);
    expect(s.updateCheckInterval, UpdateCheckInterval.weekly);
    expect(s.lastUpdateCheckMs, 1700000000000);
    expect(s.skippedUpdateVersion, 'v9.9.9');
    expect(s.lastInteractionMs('album', BigInt.from(42)), 1700000000001);

    // 再落一次盘: 读回来的值必须能原样写出去(往返稳定, 不引入漂移)。
    await s.update();
    expect(File('${dir.path}/settings.json').readAsStringSync(), encoded);
  });

  test('老配置缺字段 ⇒ 保持默认值, 不报错(向后兼容)', () async {
    File('${dir.path}/settings.json')
        .writeAsStringSync(jsonEncode({'themeMode': 'light'}));

    await AppSettings.instance.load(dir.path);

    expect(AppSettings.instance.themeMode, ThemeMode.light);
    expect(AppSettings.instance.audioLevel, 'exhigh');
    expect(AppSettings.instance.gridColumns, 3);
    expect(AppSettings.instance.updateCheckInterval, UpdateCheckInterval.daily);
    expect(AppSettings.instance.closeBehavior, CloseBehavior.quit);
  });

  test('schema < 2 的 lyricSourcePreference=auto 一次性抬到 amll(迁移仍生效)', () async {
    File('${dir.path}/settings.json').writeAsStringSync(
      jsonEncode({'schemaVersion': 1, 'lyricSourcePreference': 'auto'}),
    );
    await AppSettings.instance.load(dir.path);
    expect(AppSettings.instance.lyricSourcePreference, 'amll');

    // 新 schema 下用户显式选 auto 不再被覆盖
    File('${dir.path}/settings.json').writeAsStringSync(
      jsonEncode({
        'schemaVersion': AppSettings.settingsSchemaVersion,
        'lyricSourcePreference': 'auto',
      }),
    );
    await AppSettings.instance.load(dir.path);
    expect(AppSettings.instance.lyricSourcePreference, 'auto');
  });
}
