// U-03 统一浮层入口的回归(app_sheet.dart 的 showAppSheet / showAppDialog).
//
// 这个文件盯的不是"某个面板长什么样"(那些各自的测试管), 而是**入口本身**的四件事:
//   1. sheet 默认参数 = 多数派(isScrollControlled: true / showDragHandle: true /
//      useSafeArea: false), 且真的造的是 ModalBottomSheetRoute(⇒ 能被按 route 收掉);
//   2. 泛型返回值逐字透传(退出时 pop 的值 / 点遮罩关掉时 null);
//   3. 走入口打开的面板 / 对话框都进 NcmRouteObserver 登记表, dismissAllPopups() 能收;
//   4. dialog 的 barrierDismissible 语义(默认可点遮罩关, false 时不关)。
//
// 静态门(tools/check-sheet-entry.sh)拦"又直连回去", 这里拦"入口自己坏了"。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_shell.dart'
    show
        NcmRouteObserver,
        dismissAllPopups,
        modalRouteOpen,
        openPopups,
        pageDepth;
import 'package:minincm/src/app_sheet.dart' show showAppDialog, showAppSheet;

/// 记录被 push 的路由(直接读 route 上的参数, 而不是猜视觉).
class _RouteRecorder extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
    super.didPush(route, previousRoute);
  }
}

/// 一张"打开按钮 + 面板内容"的最小宿主.
Future<_RouteRecorder> _pumpHost(
  WidgetTester tester, {
  required void Function(BuildContext context) onPressed,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final recorder = _RouteRecorder();
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [NcmRouteObserver(), recorder],
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => onPressed(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  return recorder;
}

void main() {
  setUp(() {
    // 栈计数是全局静态量: 上一个用例的树被直接换掉(没有 didPop), 不清零会让下一个
    // 用例读到上一条 route 的残留.
    pageDepth.value = 0;
    modalRouteOpen.value = false;
  });

  testWidgets('showAppSheet 默认参数 = 多数派, 且造的是 ModalBottomSheetRoute', (
    tester,
  ) async {
    Object? result;
    var done = false;
    final recorder = await _pumpHost(
      tester,
      onPressed: (context) {
        // 用 Object 而不是 void 收返回值: 断言的是"入口把 pop 的值原样交回来"
        unawaited(
          showAppSheet<Object>(
            context,
            builder: (_) =>
                const SizedBox(height: 100, child: Text('sheet-body')),
          ).then((value) {
            result = value;
            done = true;
          }),
        );
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('sheet-body'), findsOneWidget);

    final route = recorder.pushed.last;
    expect(route, isA<ModalBottomSheetRoute<Object>>());
    final sheet = route as ModalBottomSheetRoute<Object>;
    expect(sheet.isScrollControlled, isTrue, reason: '默认 = 多数派(20 处里 13 处)');
    expect(sheet.showDragHandle, isTrue, reason: '默认 = 多数派(20 处里 19 处)');
    expect(sheet.useSafeArea, isFalse, reason: '与 showModalBottomSheet 默认一致');

    // 点遮罩(面板之上)关掉: 返回 null, 与 showModalBottomSheet 同口径
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.text('sheet-body'), findsNothing);
    expect(done, isTrue);
    expect(result, isNull);
  });

  testWidgets('showAppSheet: 少数派参数逐个透传(isScrollControlled/showDragHandle)', (
    tester,
  ) async {
    final recorder = await _pumpHost(
      tester,
      onPressed: (context) {
        unawaited(
          showAppSheet<void>(
            context,
            isScrollControlled: false,
            showDragHandle: false,
            builder: (_) => const SizedBox(height: 100, child: Text('plain')),
          ),
        );
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final sheet = recorder.pushed.last as ModalBottomSheetRoute<void>;
    expect(sheet.isScrollControlled, isFalse);
    expect(sheet.showDragHandle, isFalse);
  });

  testWidgets('showAppSheet: initialHeight 是屏高比例(400x800 屏高 800 → 0.5 = 400)', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      onPressed: (context) {
        unawaited(
          showAppSheet<void>(
            context,
            initialHeight: 0.5,
            showDragHandle: false,
            builder: (_) => const _FixedHeight(),
          ),
        );
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // BottomSheet 的高度由内容决定 ⇒ 正好是 wrapper 给的 0.5 * 屏高
    expect(tester.getSize(find.byType(BottomSheet)).height, 400);
  });

  testWidgets('showAppDialog: 返回值与 barrierDismissible 默认语义', (tester) async {
    final answered = Completer<String?>();
    final recorder = await _pumpHost(
      tester,
      onPressed: (context) {
        unawaited(
          showAppDialog<String>(
            context,
            builder: (ctx) => AlertDialog(
              title: const Text('d-1'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop('picked'),
                  child: const Text('ok'),
                ),
              ],
            ),
          ).then(answered.complete),
        );
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final dialog = recorder.pushed.last;
    expect(
      dialog,
      isA<DialogRoute<String>>(),
      reason: 'dialog 走 DialogRoute(也是 PopupRoute)',
    );
    expect(
      (dialog as PopupRoute<String>).barrierDismissible,
      isTrue,
      reason: '与 showDialog 默认一致',
    );

    await tester.tap(find.text('ok'));
    await tester.pumpAndSettle();
    expect(await answered.future, 'picked');
  });

  testWidgets('showAppDialog(barrierDismissible: false): 点遮罩不关', (
    tester,
  ) async {
    final recorder = await _pumpHost(
      tester,
      onPressed: (context) {
        unawaited(
          showAppDialog<void>(
            context,
            barrierDismissible: false,
            builder: (_) => const AlertDialog(title: Text('d-2')),
          ),
        );
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      (recorder.pushed.last as PopupRoute<void>).barrierDismissible,
      isFalse,
    );

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.text('d-2'), findsOneWidget, reason: '不可遮罩关闭');
  });

  testWidgets('入口打开的面板/对话框都进登记表, dismissAllPopups 一次收掉两层', (tester) async {
    // 登记表是全局静态量: 前面用例的树被直接换掉, 表里可能残留已失效的旧 route,
    // 所以这里按"自己的两条 route 是否进表/出表"断言, 不按绝对条数。
    final before = openPopups.length;
    final recorder = await _pumpHost(
      tester,
      onPressed: (context) {
        unawaited(
          showAppSheet<void>(
            context,
            builder: (sheetCtx) => SizedBox(
              height: 200,
              child: TextButton(
                onPressed: () => unawaited(
                  showAppDialog<void>(
                    sheetCtx,
                    builder: (_) => const AlertDialog(title: Text('d-3')),
                  ),
                ),
                child: const Text('open-dialog'),
              ),
            ),
          ),
        );
      },
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open-dialog'));
    await tester.pumpAndSettle();
    expect(find.text('d-3'), findsOneWidget);
    final sheetRoute = recorder.pushed[1]; // [0] = 宿主路由
    final dialogRoute = recorder.pushed.last;
    expect(openPopups.length, before + 2, reason: 'sheet + dialog 都进登记表');
    expect(openPopups, contains(sheetRoute));
    expect(openPopups, contains(dialogRoute));

    expect(dismissAllPopups(), greaterThanOrEqualTo(2));
    await tester.pumpAndSettle();
    expect(find.text('d-3'), findsNothing);
    expect(find.text('open-dialog'), findsNothing);
    expect(openPopups, isNot(contains(sheetRoute)));
    expect(openPopups, isNot(contains(dialogRoute)));
    expect(pageDepth.value, 1, reason: '浮层不算一层, 不许误退页面');
  });
}

/// 固定 100 高的内容(给 initialHeight 用例当"不自己定高"的 builder).
class _FixedHeight extends StatelessWidget {
  const _FixedHeight();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 100);
}
