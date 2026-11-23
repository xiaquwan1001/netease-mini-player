import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail_faces.dart';

/// 歌曲详情页「歌词 ⇄ 封面」切换(U1, 2026-11-18 用户需求:
/// 「详情页点击一次用于歌曲/播客图片与歌词之间切换, 支持查看原图和保存」)。
///
/// 口径(2026-11-19 用户 4 条反馈批后):
/// - 轻点歌词区 → 封面面(歌词 Offstage, 不可见但状态还在); 再轻点封面 → 回歌词;
/// - **换曲/换节目不再回歌词**(面是记忆的, 见 AppSettings.detailFace);
/// - 封面面首帧就有图(播放条同档小图), 大图异步淡入且每首歌只取一次;
/// - 封面面右下角「查看评论」由页面注入回调, null 时不出现;
/// - 封面面**左下角**显示「当前进度 / 总时长」(2026-11-20; 取代原来的
///   「轻点画面返回歌词」提示, 切面手势本身不靠文字解释)。位置由页面注入
///   [ValueListenable](控件不开定时器), 总时长 ≤0 时那位显示 `--:--`;
/// - 「保存封面 / 保存原图」的默认实现走 `ncm/share.saveImage` 通道 ——
///   这条用例是 \`??\` LUB 退化(位置参数回调 vs 命名参数实现 ⇒ NoSuchMethodError)
///   的回归网: 不注入 saveImage, 只 mock 通道。
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

/// 1x1 透明 PNG: Image.memory 拿它当"大图字节", 解码不会失败(也不联网)
final Uint8List _png1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIA'
  'X8jx0gAAAABJRU5ErkJggg==',
);

const MethodChannel _shareChannel = MethodChannel('ncm/share');

/// mock `ncm/share` 的 saveImage(Android MediaStore 那条通道), 记录调用
List<MethodCall> _mockSaveImage(WidgetTester tester, {String result = '系统图库'}) {
  final calls = <MethodCall>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_shareChannel, (call) async {
    calls.add(call);
    return result;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(_shareChannel, null));
  return calls;
}

void main() {
  testWidgets('轻点歌词切到封面(歌词不可见), 再轻点封面回歌词', (tester) async {
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async => _png1x1,
        ),
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
          fetchImage: (url) async => _png1x1,
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
          fetchImage: (url) async => _png1x1,
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

  testWidgets('换曲(trackId 变)不重置面, 但大图缓存按歌失效', (tester) async {
    var fetches = 0;
    Widget build(BigInt id, String cover) => _app(
      DetailFaces(
        trackId: id,
        coverUrl: cover,
        lyrics: _lyrics(),
        fetchImage: (url) async {
          fetches++;
          return _png1x1;
        },
      ),
    );

    await tester.pumpWidget(build(BigInt.one, _cover));
    await tester.tap(find.text('第0句'));
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);
    expect(fetches, 1, reason: '切到封面面才开始取大图');

    // 换歌: 面**不重置**(用户 2026-11-19: 切面要记住, 换歌也不回歌词)
    await tester.pumpWidget(
      build(BigInt.two, 'https://p1.music.126.net/x/y.jpg'),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);
    expect(find.text('第0句'), findsNothing);
    expect(fetches, 2, reason: '换歌要重新取新歌的大图');
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
          saveImage: (bytes, {required String filename}) async {
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
          saveImage: (bytes, {required String filename}) async =>
              throw StateError('无写入权限'),
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

  // ---------------- A0: 默认保存实现的回归网(LUB 退化) ----------------

  testWidgets('默认保存实现: 不注入 saveImage 也走 ncm/share.saveImage 通道', (
    tester,
  ) async {
    // 强制 Android 分支(image_io 用 defaultTargetPlatform 判平台): 于是默认实现
    // = saveImageBytes → ncm/share.saveImage。若 `??` 两侧签名再退化, 这里会以
    // NoSuchMethodError 失败。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // 必须在**测试体内**复位: flutter_test 在 body 结束、tearDown 之前就校验
    // foundation 调试变量("The value of a foundation debug variable was changed")
    try {
      final calls = _mockSaveImage(tester);

      await tester.pumpWidget(
        _app(
          DetailFaces(
            trackId: BigInt.one,
            coverUrl: _cover,
            lyrics: _lyrics(),
            // 只注入取图(免联网), **不注入**保存实现
            fetchImage: (url) async => _png1x1,
          ),
        ),
      );
      await tester.tap(find.text('第0句'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('detail-cover-save')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveImage');
      final args = calls.single.arguments as Map<Object?, Object?>;
      expect(args['filename'], startsWith('MiniNCM_cover_'));
      expect(args['filename'], endsWith('.jpg'));
      expect(args['bytes'], isA<Uint8List>());
      expect(find.text('封面已保存: 系统图库'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('全屏看图: 默认保存实现同样走 ncm/share.saveImage 通道', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final calls = _mockSaveImage(tester);

      await tester.pumpWidget(
        _app(
          DetailFaces(
            trackId: BigInt.one,
            coverUrl: _cover,
            lyrics: _lyrics(),
            fetchImage: (url) async => _png1x1,
          ),
        ),
      );
      await tester.tap(find.text('第0句'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('detail-cover-view')));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('保存原图'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveImage');
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['filename'],
        startsWith('MiniNCM_'),
      );
      expect(find.text('原图已保存: 系统图库'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // ---------------- A0b: 切面首帧出图 + 大图只取一次 ----------------

  testWidgets('封面面首帧就有图(小图), 大图只取一次; 来回切面不重复取图', (tester) async {
    var fetches = 0;
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async {
            fetches++;
            return _png1x1;
          },
        ),
      ),
    );

    await tester.tap(find.text('第0句'));
    await tester.pump();

    // 第一帧: 小图已经在位(不再白屏等 1600 大图)
    expect(find.byKey(const ValueKey('detail-cover-thumb')), findsOneWidget);
    expect(fetches, 1);

    // 大图字节到了 → 叠上来
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-cover-full')), findsOneWidget);

    // 连续来回切 3 轮: 取图/解码次数不增加
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byKey(const ValueKey('detail-cover-face')));
      await tester.pump();
      await tester.tap(find.text('第0句'));
      await tester.pump();
      expect(find.byKey(const ValueKey('detail-cover-full')), findsOneWidget);
    }
    expect(fetches, 1, reason: '同一首歌的大图字节缓存在 State 里, 只取一次');
  });

  // ---------------- A1: 封面面「查看评论」 ----------------

  testWidgets('注入 onOpenComments ⇒ 按钮在保存左边, 点一次触发一次', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async => _png1x1,
          onOpenComments: () => taps++,
        ),
      ),
    );
    await tester.tap(find.text('第0句'));
    await tester.pump();

    final comments = find.byKey(const ValueKey('detail-cover-comments'));
    expect(comments, findsOneWidget);
    expect(find.byTooltip('查看评论'), findsOneWidget);
    // 位置: 在「保存封面」左边
    expect(
      tester.getCenter(comments).dx,
      lessThan(
        tester.getCenter(find.byKey(const ValueKey('detail-cover-save'))).dx,
      ),
    );

    await tester.tap(comments);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('未注入 onOpenComments ⇒ 不出现评论按钮', (tester) async {
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async => _png1x1,
        ),
      ),
    );
    await tester.tap(find.text('第0句'));
    await tester.pump();

    expect(find.byKey(const ValueKey('detail-cover-comments')), findsNothing);
    expect(find.byTooltip('查看评论'), findsNothing);
  });

  // ---------------- A2: 面记忆 + 播放条封面点击 ----------------

  testWidgets('initialFace=cover ⇒ 首帧就是封面面; 手动切面回灌 onFaceChanged', (
    tester,
  ) async {
    final changed = <DetailFace>[];
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          initialFace: DetailFace.cover,
          onFaceChanged: changed.add,
          fetchImage: (url) async => _png1x1,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('detail-cover-face')));
    await tester.pump();
    expect(find.text('第0句'), findsOneWidget);
    expect(changed, [DetailFace.lyrics]);
  });

  testWidgets('播放条封面点击: 记忆面翻到另一面, 两下回到原面', (tester) async {
    final face = ValueNotifier<DetailFace>(DetailFace.lyrics);
    addTearDown(face.dispose);
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          faceController: face,
          fetchImage: (url) async => _png1x1,
        ),
      ),
    );
    expect(find.text('第0句'), findsOneWidget);

    // home_page 的「点封面」= 把记忆面翻到另一面(见 onOpenDetail)
    face.value = oppositeDetailFace(face.value);
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-cover-face')), findsOneWidget);

    face.value = oppositeDetailFace(face.value);
    await tester.pump();
    expect(find.byKey(const ValueKey('detail-cover-face')), findsNothing);
    expect(find.text('第0句'), findsOneWidget);

    // 用户手动切面 → 控制器跟着走(下一次点封面才从正确的面翻起)
    await tester.tap(find.text('第0句'));
    await tester.pump();
    expect(face.value, DetailFace.cover);
  });

  testWidgets('oppositeDetailFace 是纯翻面(两下回到原点)', (tester) async {
    expect(oppositeDetailFace(DetailFace.lyrics), DetailFace.cover);
    expect(oppositeDetailFace(DetailFace.cover), DetailFace.lyrics);
    expect(
      oppositeDetailFace(oppositeDetailFace(DetailFace.lyrics)),
      DetailFace.lyrics,
    );
  });

  // ---------------- A3: 封面面「当前进度 / 总时长」 ----------------

  testWidgets('封面面左下角显示「当前进度 / 总时长」, 并随注入的位置刷新', (tester) async {
    final position = ValueNotifier<int>(83000);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async => _png1x1,
          positionMs: position,
          durationMs: 296000,
        ),
      ),
    );
    // 歌词面时不出现(只有封面面那一行)
    expect(find.byKey(const ValueKey('detail-cover-progress')), findsNothing);

    await tester.tap(find.text('第0句'));
    await tester.pump();

    expect(find.text('1:23 / 4:56'), findsOneWidget);
    expect(find.text('轻点画面返回歌词'), findsNothing);

    // 高频源(页面注入的 positionMs)变一次就跟着变一次
    position.value = 125000;
    await tester.pump();
    expect(find.text('2:05 / 4:56'), findsOneWidget);
  });

  testWidgets('总时长 ≤0 ⇒ `--:--`; 未注入位置时不崩且显示 0:00', (tester) async {
    final position = ValueNotifier<int>(0);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async => _png1x1,
          positionMs: position,
          // 还没拿到时长(或直播/未知): 不能显示成 0 秒的假总时长
          durationMs: 0,
        ),
      ),
    );
    await tester.tap(find.text('第0句'));
    await tester.pump();
    expect(find.text('0:00 / --:--'), findsOneWidget);

    // 负值同样归到 `--:--`(上游异常时不留回绕的时间)
    await tester.pumpWidget(
      _app(
        DetailFaces(
          trackId: BigInt.one,
          coverUrl: _cover,
          lyrics: _lyrics(),
          fetchImage: (url) async => _png1x1,
          positionMs: position,
          durationMs: -1000,
        ),
      ),
    );
    expect(find.text('0:00 / --:--'), findsOneWidget);

    // 完全不注入位置(纯控件/无当前曲目): 静态 `0:00 / --:--`, 不崩
    await tester.pumpWidget(
      _app(DetailFaces(trackId: BigInt.one, coverUrl: null, lyrics: _lyrics())),
    );
    // 同一 State 续用, 面仍停在封面面(记忆), 不需要再切
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('0:00 / --:--'), findsOneWidget);
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
                fetchImage: (url) async => _png1x1,
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
