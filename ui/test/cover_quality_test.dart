// 封面清晰度档位 + 全屏看图「保存原图」的离线单测(不联网, 不落盘)。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/cover_art.dart';
import 'package:minincm/src/cover_quality_sheet.dart';

/// 在指定 devicePixelRatio 下取 coverRequestPx 的结果
Future<double> pxAt(
  WidgetTester tester, {
  required double dpr,
  required double size,
  CoverQuality? quality,
}) async {
  late double px;
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(devicePixelRatio: dpr),
      child: Builder(builder: (context) {
        px = coverRequestPx(context, size, quality: quality);
        return const SizedBox.shrink();
      }),
    ),
  ));
  return px;
}

void main() {
  setUp(() {
    AppSettings.instance.coverQuality = CoverQuality.standard;
  });

  group('coverRequestPx: 按设备像素 × 档位取图', () {
    testWidgets('标准档 = 显示尺寸 x DPR(不再拿逻辑尺寸当像素)', (tester) async {
      expect(await pxAt(tester, dpr: 1, size: 44), 60, reason: '1x 屏也至少 60px');
      expect(await pxAt(tester, dpr: 2, size: 44), 88);
      expect(await pxAt(tester, dpr: 3, size: 44), 132);
      expect(await pxAt(tester, dpr: 2.75, size: 118), 325);
    });

    testWidgets('省流 0.75x / 超清 2x, 相对标准单调', (tester) async {
      final saver = await pxAt(tester, dpr: 3, size: 100, quality: CoverQuality.dataSaver);
      final std = await pxAt(tester, dpr: 3, size: 100, quality: CoverQuality.standard);
      final ultra = await pxAt(tester, dpr: 3, size: 100, quality: CoverQuality.ultra);
      expect(saver, 225);
      expect(std, 300);
      expect(ultra, 600);
      expect(saver < std && std < ultra, isTrue);
    });

    testWidgets('上下限: 最小 60, 最大 1600', (tester) async {
      expect(await pxAt(tester, dpr: 1, size: 8), 60);
      expect(await pxAt(tester, dpr: 4, size: 1200, quality: CoverQuality.ultra), 1600);
    });

    test('neteaseThumbUrl 把像素写进 param', () {
      const url = 'https://p1.music.126.net/a/b.jpg';
      expect(neteaseThumbUrl(url, width: 132, height: 132), '$url?param=132y132');
      expect(neteaseThumbUrl('$url?x=1', width: 60, height: 60), '$url?x=1&param=60y60');
      expect(neteaseThumbUrl(url, width: double.infinity), url, reason: '全宽不算 param');
    });
  });

  group('CoverArt 组件级: 真正请求的 URL 像素', () {
    Future<String?> renderedUrl(WidgetTester tester, double dpr) async {
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(devicePixelRatio: dpr),
          child: const Center(
              child: CoverArt(url: 'https://p3.music.126.net/a/b.jpg', size: 44)),
        ),
      ));
      final images = find.byType(Image).evaluate().toList();
      if (images.isEmpty) return null;
      return (images.first.widget as Image).image.toString();
    }

    testWidgets('44dp @3x 标准档 -> 请求 132px', (tester) async {
      AppSettings.instance.coverQuality = CoverQuality.standard;
      final url = await renderedUrl(tester, 3);
      expect(url, isNotNull);
      expect(url!, contains('param=132y132'));
    });

    testWidgets('切到超清后同一个封面改请求 264px(不重启)', (tester) async {
      AppSettings.instance.coverQuality = CoverQuality.standard;
      await renderedUrl(tester, 3);
      AppSettings.instance.coverQuality = CoverQuality.ultra;
      await tester.pump();
      final images = find.byType(Image).evaluate().toList();
      final url = (images.first.widget as Image).image.toString();
      expect(url, contains('param=264y264'));
    });
  });

  group('档位持久化', () {
    test('id 往返 + 未知值回落标准', () {
      for (final tier in CoverQuality.values) {
        expect(CoverQualityX.fromId(tier.id), tier);
      }
      expect(CoverQualityX.fromId('nope'), CoverQuality.standard);
      expect(CoverQualityX.fromId(null), CoverQuality.standard);
    });

    test('写盘后读回: coverQuality 跟着走', () async {
      final dir = Directory.systemTemp.createTempSync('minincm-cover');
      addTearDown(() => dir.deleteSync(recursive: true));
      final settings = AppSettings.instance;
      await settings.load(dir.path);
      await settings.update(coverQuality: CoverQuality.ultra, showHotSearch: true);
      final raw = jsonDecode(
          File('${dir.path}/settings.json').readAsStringSync()) as Map;
      expect(raw['coverQuality'], 'ultra');

      // 读回(同一个 dataDir)
      settings.coverQuality = CoverQuality.dataSaver; // 先污染成别的值
      await settings.load(dir.path);
      expect(settings.coverQuality, CoverQuality.ultra);
    });
  });

  group('设置面板 UI', () {
    testWidgets('三档都列出来, 点「超清」写设置并关闭面板', (tester) async {
      AppSettings.instance.coverQuality = CoverQuality.standard;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showCoverQualitySheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      for (final tier in CoverQuality.values) {
        expect(find.text(tier.label), findsOneWidget);
      }
      expect(find.text(CoverQuality.standard.hint), findsOneWidget);

      await tester.tap(find.text('超清'));
      await tester.pumpAndSettle();
      expect(AppSettings.instance.coverQuality, CoverQuality.ultra);
      expect(find.text('省流'), findsNothing, reason: '选完面板应关闭');
    });
  });

  group('全屏看图: 保存原图', () {
    Future<void> openViewer(
      WidgetTester tester, {
      required Future<Uint8List> Function(String) fetch,
      required Future<String> Function(Uint8List, String) save,
      List<String> urls = const ['http://p3.music.126.net/a/cover.jpg'],
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showImageViewer(context,
                    urls: urls, fetchOverride: fetch, saveOverride: save),
                child: const Text('view'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('view'));
      await tester.pump();
    }

    testWidgets('点下载: 取原图字节并保存, 文件名带扩展名', (tester) async {
      final fetched = <String>[];
      final saved = <String, int>{};
      await openViewer(
        tester,
        fetch: (url) async {
          fetched.add(url);
          return Uint8List.fromList(List<int>.filled(2048, 7));
        },
        save: (bytes, name) async {
          saved[name] = bytes.length;
          return '/tmp/$name';
        },
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('保存原图'), findsOneWidget);
      await tester.tap(find.byTooltip('保存原图'));
      await tester.pumpAndSettle();

      expect(fetched, ['https://p3.music.126.net/a/cover.jpg'],
          reason: 'http 直链要升级成 https');
      expect(saved.length, 1);
      final name = saved.keys.first;
      expect(name.endsWith('.jpg'), isTrue);
      expect(saved[name], 2048, reason: '存的是原图字节(不是缩略图)');
      expect(find.textContaining('原图已保存'), findsOneWidget);
    });

    testWidgets('取图失败: 提示保存失败, 不抛异常', (tester) async {
      await openViewer(
        tester,
        fetch: (url) async => throw const SocketException('boom'),
        save: (bytes, name) async => '/tmp/$name',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('保存原图'));
      await tester.pumpAndSettle();
      expect(find.textContaining('保存失败'), findsOneWidget);
    });

    testWidgets('关闭按钮直接退出, 多图显示序号', (tester) async {
      await openViewer(
        tester,
        fetch: (url) async => Uint8List(0),
        save: (bytes, name) async => name,
        urls: const [
          'https://p3.music.126.net/a/1.jpg',
          'https://p3.music.126.net/a/2.jpg',
        ],
      );
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('保存原图'), findsNothing);
    });
  });

  testWidgets('300dp + 1.25 字号: 档位面板不溢出且三档可见', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    AppSettings.instance.coverQuality = CoverQuality.standard;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showCoverQualitySheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    for (final tier in CoverQuality.values) {
      expect(find.text(tier.label), findsOneWidget);
    }
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(1.25)),
      child: child!,
    ),
    home: home,
  ));
}
