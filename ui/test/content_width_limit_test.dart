// 宽屏内容限宽(lane/ui-adaptive P2)的几何回归。
//
// 口径(见 lib/src/layout.dart 的 ContentWidthLimit):
//   · 可用宽 <= kContentMaxWidth(840) ⇒ **原样返回**, 内容铺满(窄/中屏零变化);
//   · 可用宽 > 840 ⇒ 内容居中, 最大宽 840, 两侧留白 = (可用宽 - 840) / 2。
//
// 断言的是**实际渲染坐标**(不是 widget 树形状): 400/840 两档必须与改动前
// 完全一致(左边距 0 / 宽度 = 视口宽), 1280 档才出现居中留白。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';
import 'package:minincm/src/layout.dart';

const Key _contentKey = Key('content-width-probe');

/// 走真实壳(PlayerBarHost), 内容区放一个可测量的探针。
///
/// 探针用 SizedBox.expand: 它会吃掉 ContentWidthLimit 给出的全部可用宽,
/// 所以量到的宽就是「页面真正能用的宽」。
Future<void> pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => playerBarSlot.value = null);
  addTearDown(() => modalRouteOpen.value = false);
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [NcmRouteObserver()],
      builder: (context, child) =>
          PlayerBarHost(content: child ?? const SizedBox.shrink()),
      home: const Scaffold(
        body: SizedBox.expand(key: _contentKey, child: Text('内容')),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('400 宽(窄档): 内容铺满, 与改动前完全一致', (tester) async {
    await pumpShell(tester, const Size(400, 800));
    final rect = tester.getRect(find.byKey(_contentKey));
    expect(rect.width, 400, reason: '窄屏不允许出现限宽');
    expect(rect.left, 0, reason: '窄屏不允许出现居中偏移');
    expect(rect.height, 800, reason: '限宽盒不该改变高度');
    // 窄屏连包装层都不该插入
    expect(find.byType(ContentWidthLimit), findsOneWidget);
  });

  testWidgets('840 宽(刚好等于限宽): 仍是铺满, 无左右留白', (tester) async {
    await pumpShell(tester, const Size(840, 800));
    final rect = tester.getRect(find.byKey(_contentKey));
    expect(rect.width, kContentMaxWidth);
    expect(rect.left, 0, reason: '等于限宽时不该居中留白(边界不抖动)');
  });

  testWidgets('1280 宽(宽档): 内容最大 840 且居中', (tester) async {
    await pumpShell(tester, const Size(1280, 800));
    final rect = tester.getRect(find.byKey(_contentKey));
    expect(rect.width, kContentMaxWidth, reason: '内容区应被限宽到 kContentMaxWidth');
    expect(rect.left, (1280 - kContentMaxWidth) / 2, reason: '内容区应水平居中');
    expect(rect.height, 800, reason: '限宽盒不该改变高度(不含播放条时内容满高)');
  });

  testWidgets('宽屏两侧留白用 scaffoldBackgroundColor(不露黑/透明边)', (tester) async {
    await pumpShell(tester, const Size(1280, 800));
    final box = tester.widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(ContentWidthLimit),
            matching: find.byType(ColoredBox),
          )
          .first,
    );
    final scaffoldColor = tester
        .widget<Material>(find.byType(Material).first)
        .color;
    expect(box.color, scaffoldColor, reason: '留白底色必须与页面 Scaffold 底色一致');
  });

  // 弹层与限宽盒的关系(2026-11-18 编排者复核补):
  //
  // 限宽盒包在 Navigator 外面 ⇒ 弹层的 ModalBarrier 也只有 840 宽。这是**已接受**的
  // 边界(要遮罩通栏就得把限宽下移到 150+ 个页面, 判定不做), 但两侧留白必须跟着压暗,
  // 否则 1280 窗口下遮罩看起来"破了两条"。这里同时锁住两件事:
  //   ① 遮罩宽度 == kContentMaxWidth(边界被显式记录, 哪天变了测试会提醒);
  //   ② 弹层在场时留白颜色 == alphaBlend(black54, scaffoldBackgroundColor);
  //   ③ 弹层关掉后留白回到 scaffoldBackgroundColor。
  testWidgets('1280 宽 + 弹层: 遮罩只有 840(已知边界), 两侧留白跟着压暗', (tester) async {
    const viewport = Size(1280, 800);
    await pumpShell(tester, viewport);
    final scaffoldColor = tester
        .widget<Material>(find.byType(Material).first)
        .color;
    final ctx = tester.element(find.byKey(_contentKey));

    showDialog<void>(
      context: ctx,
      builder: (_) => const AlertDialog(title: Text('弹层')),
    );
    await tester.pumpAndSettle();

    expect(modalRouteOpen.value, isTrue, reason: 'PopupRoute 进场应置位弹层标记');
    final barrierWidths = find
        .byType(ModalBarrier)
        .evaluate()
        .map((e) => tester.getSize(find.byWidget(e.widget)).width);
    expect(
      barrierWidths,
      contains(kContentMaxWidth),
      reason: '遮罩被内容限宽一起收窄(已知边界), 变了就要重看这条测试的注释',
    );
    expect(
      _gapBoxColor(tester, viewport),
      Color.alphaBlend(kContentGapBarrierColor, scaffoldColor!),
      reason: '弹层在场时两侧留白必须与遮罩同色, 否则视觉上遮罩只有中间一条',
    );

    Navigator.of(ctx).pop();
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isFalse, reason: '弹层退场应复位');
    expect(
      _gapBoxColor(tester, viewport),
      scaffoldColor,
      reason: '弹层关掉后留白回到页面底色',
    );
  });
}

/// 取"两侧留白"那个 ColoredBox 的颜色: 它是限宽盒唯一的整屏尺寸填充盒
/// (弹层的遮罩 ColoredBox 只有 840 宽, 用尺寸区分)。
Color _gapBoxColor(WidgetTester tester, Size viewport) {
  final finder = find.descendant(
    of: find.byType(ContentWidthLimit),
    matching: find.byType(ColoredBox),
  );
  for (final element in finder.evaluate()) {
    final box = element.widget as ColoredBox;
    final size = tester.getSize(find.byWidget(box));
    if (size.width == viewport.width) return box.color;
  }
  fail('没有找到铺满视口的两侧留白 ColoredBox');
}
