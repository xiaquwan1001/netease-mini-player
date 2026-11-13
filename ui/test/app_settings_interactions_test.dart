import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';

/// 「我的」页排序用的交互记录: 跟着 settings.json 持久化, 上限 200 条.
///
/// 用普通 test() 而非 testWidgets: testWidgets 的 FakeAsync 里真 IO 永远不完成,
/// 这里的落盘断言必须走真实文件系统。
void main() {
  late Directory dir;
  final settings = AppSettings.instance;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ncm_settings_interactions');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Map<String, dynamic> readSettings() =>
      jsonDecode(File('${dir.path}/settings.json').readAsStringSync())
          as Map<String, dynamic>;

  test('旧配置没有 interactions 字段时按空记录读, 不报错', () async {
    File(
      '${dir.path}/settings.json',
    ).writeAsStringSync(jsonEncode({'themeMode': 'dark', 'textScale': 1.15}));
    await settings.load(dir.path);

    expect(settings.loaded, isTrue);
    expect(settings.lastInteractionMs('album', BigInt.from(1)), isNull);
    expect(settings.themeMode, isNotNull);
  });

  test('touchInteraction 记录时间并落盘到 settings.json 的 interactions', () async {
    await settings.load(dir.path);

    await settings.touchInteraction('album', BigInt.from(123), nowMs: 111);
    await settings.touchInteraction('podcast', BigInt.from(45), nowMs: 222);

    expect(settings.lastInteractionMs('album', BigInt.from(123)), 111);
    expect(settings.lastInteractionMs('podcast', BigInt.from(45)), 222);
    // 未记录过的条目为 null
    expect(settings.lastInteractionMs('podcast', BigInt.from(123)), isNull);

    final raw = readSettings();
    final interactions = raw['interactions'] as Map<String, dynamic>;
    expect(interactions['album:123'], 111);
    expect(interactions['podcast:45'], 222);
  });

  test('同一 key 重复交互只更新时间, 不重复占位', () async {
    await settings.load(dir.path);

    await settings.touchInteraction('playlist', BigInt.from(7), nowMs: 10);
    final before =
        (readSettings()['interactions'] as Map<String, dynamic>).length;
    await settings.touchInteraction('playlist', BigInt.from(7), nowMs: 20);

    expect(settings.lastInteractionMs('playlist', BigInt.from(7)), 20);
    // 同一个 key 再交互只是覆盖时间, 不会多占一条
    expect(
      (readSettings()['interactions'] as Map<String, dynamic>).length,
      before,
    );
  });

  test('记录数超上限时丢最旧的(settings.json 不无限变长)', () async {
    await settings.load(dir.path);

    const limit = AppSettings.interactionLimit;
    for (var i = 0; i <= limit; i++) {
      await settings.touchInteraction('album', BigInt.from(i), nowMs: i);
    }

    // 最新一条在, 最旧的一条(nowMs = 0)已被挤掉
    expect(settings.lastInteractionMs('album', BigInt.from(limit)), limit);
    expect(settings.lastInteractionMs('album', BigInt.zero), isNull);
    expect(
      (readSettings()['interactions'] as Map<String, dynamic>).length,
      limit,
    );
  });
}
