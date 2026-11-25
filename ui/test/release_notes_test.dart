import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_meta.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/release_notes.dart';
import 'package:minincm/src/update_checker.dart';
import 'package:minincm/src/update_dialog.dart';

/// 特性公告(2026-11 用户需求「每次更新的弹窗提示加上特性公告」)。
///
/// 两条消费路径各自锁一边:
/// - 更新前的「发现新版本」弹窗: 列出**当前版本之后**的公告条目 + release 说明;
/// - 更新后的「已更新到 X」弹窗: 只列当前版本这一条(每个版本只弹一次, 由
///   `home/startup.dart` 的 promptWhatsNew 用 AppSettings.announcedVersion 把关)。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    UpdateCheckHost.openUrl = (url) async {};
  });

  test('版本归一化与「比当前新」的条目筛选', () {
    expect(normalizeVersionKey('v0.39.0'), '0.39.0');
    expect(normalizeVersionKey('V0.39.0+90'), '0.39.0');
    expect(normalizeVersionKey(' 0.39.0 '), '0.39.0');
    expect(highlightsFor('0.39.0'), isNotEmpty);
    expect(highlightsFor('v0.39.0'), isNotEmpty);
    expect(highlightsFor('v9.9.9'), isEmpty);

    // 公告表里最新的那一版(发版只改表, 不改本用例)
    final newest =
        (kReleaseHighlights.keys.toList()..sort(compareVersionKeys)).last;

    // 当前版本就是最新: 没有任何"更新后可看"的条目
    expect(highlightsSince(newest), isEmpty);
    // 从更老的版本升级上来: 0.39.0 与最新一版的条目都要列出(旧的在上)
    final since = highlightsSince('v0.38.8');
    expect(since, containsAll(kReleaseHighlights['v0.39.0']!));
    expect(since, containsAll(kReleaseHighlights[newest]!));
    // 条数必须恰好等于"所有比 0.38.8 新的版本"的条目总和: 既不能漏, 也不能把更老的拉进来
    final newerThan0388 = kReleaseHighlights.entries
        .where((e) => compareVersionKeys(e.key, 'v0.38.8') > 0)
        .fold<int>(0, (sum, e) => sum + e.value.length);
    expect(since.length, newerThan0388, reason: '只列比 0.38.8 新的那几版, 不能把更老的也拉进来');
  });

  testWidgets('发现新版本弹窗: 标题 + 新特性公告 + 更新说明都在', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showUpdateDialog(
                ctx,
                const UpdateInfo(
                  latest: 'v0.39.0',
                  current: 'v0.38.8',
                  isNewer: true,
                  notes: '例行修复',
                  downloadUrl: 'https://example.com/a.apk',
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 v0.39.0'), findsOneWidget);
    expect(find.text('新特性公告'), findsOneWidget);
    // 公告条目的第一条(用户语言, 与 GitHub release 正文分开维护)
    expect(find.text(kReleaseHighlights['v0.39.0']!.first), findsOneWidget);
    expect(find.text('更新说明'), findsOneWidget);
    expect(find.text('例行修复'), findsOneWidget);
    // 按钮不被长正文挤掉
    expect(find.text('前往下载'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
  });

  testWidgets('更新后公告弹窗: 「已更新到 X」+ 本版本条目 + 知道了', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showWhatsNewDialog(
                ctx,
                version: kAppVersion,
                highlights: kReleaseHighlights['v0.39.0']!,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('已更新到 $kAppVersion'), findsOneWidget);
    expect(find.text('新特性公告'), findsOneWidget);
    expect(find.text('知道了'), findsOneWidget);
    // 更新后公告没有下载入口(已经装上了)
    expect(find.text('前往下载'), findsNothing);
    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('已更新到 $kAppVersion'), findsNothing);
  });

  testWidgets('没有公告也没有 release 说明时给兜底文案(不空白)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UpdateNotesBody(highlights: <String>[], notes: ''),
        ),
      ),
    );
    expect(find.text('这个版本没有填写更新说明。'), findsOneWidget);
  });

  test('「已公告版本」落盘后不再重复弹(首页启动的判据)', () async {
    // 只测数据面: hadStoredSettings 需要真实 settings.json 存在才算"老用户升级"。
    final settings = AppSettings.instance;
    final dir = await Directory.systemTemp.createTemp('ncm-whats-new');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final keep = settings.announcedVersion;
    settings.announcedVersion = null;
    await settings.load(dir.path);
    await settings.markAnnounced('0.39.0');
    final raw = File('${dir.path}/settings.json').readAsStringSync();
    expect(raw, contains('"announcedVersion":"0.39.0"'));
    await settings.load(dir.path);
    expect(settings.announcedVersion, '0.39.0');
    settings.announcedVersion = keep;
  });
}
