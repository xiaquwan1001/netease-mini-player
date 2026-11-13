import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/mv_page.dart';
import 'package:minincm/src/mv_playback.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// MV 详情/播放页(C3)测试: 假 loader + 假通道, 不触网络/平台。

rust.MvDetailDto mvDetail({
  BigInt? id,
  String name = '主角',
  String artist = '王菲',
  String? coverUrl = 'https://p1.music.126.net/cover.jpg',
  int maxBr = 1080,
  String? desc,
  int playCount = 377308,
  String publishTime = '2026-05-07',
  int durationMs = 284000,
}) => rust.MvDetailDto(
  id: id ?? BigInt.from(5436712),
  name: name,
  artistName: artist,
  durationMs: BigInt.from(durationMs),
  playCount: BigInt.from(playCount),
  publishTime: publishTime,
  coverUrl: coverUrl,
  maxBr: maxBr,
  brs: Uint32List.fromList([240, 480, 1080]),
  desc: desc,
);

rust.MvUrlDto mvUrl({
  String? url = 'http://vod.example.com/a.mp4?wsSecret=x',
}) => rust.MvUrlDto(url: url, r: 480, size: BigInt.from(31157772));

/// 记录通过 ncm/mv 通道发起的播放调用
List<Map<Object?, Object?>> recordMvCalls(WidgetTester tester) {
  final calls = <Map<Object?, Object?>>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('ncm/mv'),
    (call) async {
      if (call.method == 'play') {
        final args = call.arguments;
        if (args is Map) calls.add(args.cast<Object?, Object?>());
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('ncm/mv'),
      null,
    ),
  );
  return calls;
}

/// 冒充某平台分支(Android=内嵌播放 / 桌面=外链), 不依赖真实平台
class _FakePlayback extends MvPlayback {
  _FakePlayback({required this.android});

  final bool android;

  @override
  bool get supportsInlinePlayback => android;
}

Future<void> pumpMv(
  WidgetTester tester, {
  rust.MvDetailDto? detail,
  rust.MvUrlDto? url,
  Future<rust.MvDetailDto> Function(BigInt)? loadDetail,
  MvPlayback? playback,
  bool narrow = false,
}) async {
  if (narrow) {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }
  await tester.pumpWidget(
    MaterialApp(
      builder: narrow
          ? (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.25)),
              child: child!,
            )
          : null,
      home: MvPage(
        mvId: BigInt.from(5436712),
        name: '主角',
        playback: playback ?? _FakePlayback(android: true),
        loadDetail: loadDetail ?? (_) async => detail ?? mvDetail(),
        loadUrl: (id, r) async => url ?? mvUrl(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('MV 详情渲染: 标题/艺人/播放量/发布时间/最高清晰度', (tester) async {
    await pumpMv(tester, detail: mvDetail(desc: '简介文本'));
    expect(find.text('主角'), findsWidgets);
    expect(find.textContaining('王菲'), findsOneWidget);
    expect(find.textContaining('377308'), findsOneWidget);
    expect(find.textContaining('2026-05-07'), findsOneWidget);
    expect(find.textContaining('最高 1080P'), findsOneWidget);
    expect(find.text('简介文本'), findsOneWidget);
  });

  testWidgets('加载失败时显示错误态与重试', (tester) async {
    var calls = 0;
    await pumpMv(
      tester,
      loadDetail: (_) async {
        calls++;
        if (calls == 1) throw Exception('boom');
        return mvDetail();
      },
    );
    expect(find.textContaining('重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.textContaining('王菲'), findsOneWidget);
  });

  testWidgets('无播放链接时给可读错误态, 不发播放调用', (tester) async {
    final calls = recordMvCalls(tester);
    await pumpMv(tester, url: mvUrl(url: null));
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(find.textContaining('无可播放链接'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('点击播放: 发起 ncm/mv 调用且直链转 https', (tester) async {
    final calls = recordMvCalls(tester);
    await pumpMv(tester);
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(1));
    expect(calls.single['url'], startsWith('https://vod.example.com/a.mp4'));
    expect(calls.single['title'], '主角');
  });

  testWidgets('非 Android 平台: 显示外链按钮并说明无内嵌播放', (tester) async {
    await pumpMv(tester, playback: _FakePlayback(android: false));
    expect(find.textContaining('用系统播放器打开'), findsOneWidget);
    expect(find.textContaining('没有内嵌视频播放能力'), findsOneWidget);
  });

  testWidgets('mounted 页面下取链异常时展示错误文案', (tester) async {
    final calls = recordMvCalls(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: MvPage(
          mvId: BigInt.from(1),
          name: 'm',
          playback: _FakePlayback(android: true),
          loadDetail: (_) async => mvDetail(),
          loadUrl: (_, r) async => throw Exception('403 expired'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('播放'));
    await tester.pumpAndSettle();
    expect(find.textContaining('播放失败'), findsOneWidget);
    expect(find.textContaining('403 expired'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('300dp + 1.25 字号: 详情页不溢出且关键文案可见', (tester) async {
    await pumpMv(
      tester,
      narrow: true,
      detail: mvDetail(desc: '一段特别特别长的简介文本用于窄屏回归测试超出单行不少字'),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('王菲'), findsOneWidget);
    expect(find.textContaining('最高 1080P'), findsOneWidget);
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: home,
    ),
  );
}
