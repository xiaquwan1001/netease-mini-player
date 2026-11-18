import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail_faces.dart';

/// 歌曲详情页「歌词 ⇄ 封面」切换(U1, 2026-11-18 用户需求:
/// 「详情页点击一次用于歌曲/播客图片与歌词之间切换, 支持查看原图和保存」)。
///
/// 口径:
/// - 轻点歌词区 → 封面面(歌词 Offstage, 不可见但状态还在);
/// - 再轻点封面 → 回歌词, 滚动位置不丢;
/// - 换曲/换节目(trackId 变) → 自动回歌词;
/// - 无封面 → 中性占位(不白屏), 且不出现保存/查看原图按钮;
/// - 保存走注入的假实现, 不写磁盘。
Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 歌词面的替身: 40 行固定高, 可注入 controller 以便断言滚动位置
Widget _lyrics({ScrollController? controller}) => ListView.builder(
  controller: controller,
  itemCount: 40,
  itemBuilder: (context, i) =>
      SizedBox(height: 56, child: Center(child: Text('第$i句'))),
);

const String _cover =
    'https://p1.music.126.net/abcdefghijklmnop==/109951160000000000.jpg';

void main() {
  testWidgets('轻点歌词切到封面(歌词不可见), 再轻点封面回歌词', (tester) async {
    await tester.pumpWidget(
      _app(
        DetailFaces(trackId: BigInt.one, coverUrl: _cover, lyrics: _lyrics()),
      ),
    );
    expect(find.text('第0句'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-cover-face')), findsNothing);

    await tester.tap(find.text('第0句'));
    await tester.pump();

    expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);
    // Offstage: 默认 finder 跳过, 等价于"歌词不可见"
    expect(find.text('第0句'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('detail-cover-face')));
    await tester.pump();

    expect(find.byKey(const ValueKey('detail-cover-face')), findsNothing);
    expect(find.text('第0句'), findsOneWidget);
  });

  testWidgets('切回歌词保持原滚动位置(歌词面 Offstage 常驻)', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(controller: controller),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final offset = controller.offset;
    expect(offset, greaterThan(0));

    // 拖动后可见的是第 7~14 句左右, 轻点其中一句切面
    await tester.tap(find.text('第8句'));
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);
    expect(controller.offset, offset);

    await tester.tap(find.byKey(const ValueKey('detail-cover-face')));
    await tester.pump();
    expect(controller.offset, offset);
  });

  testWidgets('多选态(tappable=false)轻点不切面', (tester) async {
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          tappable: false,
          lyrics: _lyrics(),
        ),
      ),
    );
    await tester.tap(find.text('第0句'));
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-cover-face')), findsNothing);
    expect(find.text('第0句'), findsOneWidget);
  });

  testWidgets('无封面: 中性占位 + 不出现保存/查看原图按钮', (tester) async {
    await tester.pumpWidget(
      _app(DetailFaces(trackId: BigInt.one, coverUrl: null, lyrics: _lyrics())),
    );
    await tester.tap(find.text('第0句'));
    await tester.pump();

    expect(
      find.byKey(const ValueKey('detail-cover-placeholder')),
      findsOneWidget,
    );
    expect(find.text('暂无封面'), findsOneWidget);
    expect(find.byKey(const ValueKey('detail-cover-save')), findsNothing);
    expect(find.byKey(const ValueKey('detail-cover-view')), findsNothing);
  });

  testWidgets('换曲(trackId 变)自动回到歌词面', (tester) async {
    Widget build(BigInt id) =>
        _app(DetailFaces(trackId: id, coverUrl: _cover, lyrics: _lyrics()));

    await tester.pumpWidget(build(BigInt.one));
    await tester.tap(find.text('第0句'));
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);

    await tester.pumpWidget(build(BigInt.two));
    await tester.pump();

    expect(find.byKey(const ValueKey('detail-cover-face')), findsNothing);
    expect(find.text('第0句'), findsOneWidget);
  });

  testWidgets('保存走注入的假实现(不写磁盘/不联网)', (tester) async {
    String? fetchedUrl;
    Uint8List? savedBytes;
    String? savedName;
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async {
            fetchedUrl = url;
            return Uint8List.fromList(const [1, 2, 3]);
          },
          saveImage: (bytes, filename) async {
            savedBytes = bytes;
            savedName = filename;
            return '/tmp/MiniNCM/$filename';
          },
        ),
      ),
    );
    await tester.tap(find.text('第0句'));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('detail-cover-save')));
    // 两帧: 一帧跑完 await 链, 一帧把 SnackBar 挂上
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fetchedUrl, _cover);
    expect(savedBytes, const [1, 2, 3]);
    expect(savedName, isNotNull);
    expect(savedName, endsWith('.jpg'));
    expect(savedName, startsWith('MiniNCM_cover_'));
    expect(find.textContaining('封面已保存'), findsOneWidget);
  });

  testWidgets('保存失败给可读文案, 不崩', (tester) async {
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async => Uint8List.fromList(const [1]),
          saveImage: (bytes, filename) async => throw StateError('无写入权限'),
        ),
      ),
    );
    await tester.tap(find.text('第0句'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('detail-cover-save')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('保存失败'), findsOneWidget);
  });

  for (final (size, scale) in <(Size, double)>[
    (const Size(280, 600), 1.25),
    (const Size(280, 600), 1.625),
    (const Size(300, 640), 1.25),
    (const Size(300, 640), 1.625),
  ]) {
    testWidgets('${size.width.toInt()}dp + ${scale}x 字号: 两个面都不溢出', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: DetailFaces(
                key: const ValueKey('with-cover'),
                trackId: BigInt.one,
                coverUrl: _cover,
                lyrics: _lyrics(),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('第0句'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);

      // 无封面占位在小屏 + 大字号下同样不溢出
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: DetailFaces(
                key: const ValueKey('no-cover'),
                trackId: BigInt.one,
                coverUrl: null,
                lyrics: _lyrics(),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('第0句'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('暂无封面'), findsOneWidget);
    });
  }
}
