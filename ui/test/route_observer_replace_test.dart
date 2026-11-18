// U-07 回归: NcmRouteObserver 处理 didReplace(`pushReplacement`)。
//
// 背景(arch-audit-ui-overlay-2026-11-18 P3/U-07): 观察者只接了 didPush/didPop/
// didRemove。`pushReplacement` 走的是 didReplace, 一条都不记 ⇒ 被换掉那条的账
// 永远收不回来:
//   - 全屏页 → 弹层: pageDepth 停在 2, 底部导航再也不出现;
//   - 弹层 → 全屏页: modalRouteOpen 永久 true(宽屏两侧留白一直压暗),
//     而且弹层登记表里留着死 route, dismissAllPopups() 会去关一条不在栈上的浮层。
//
// 修法(didReplace): 先摘旧的、再挂新的, 口径与 push/pop 完全一致。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_shell.dart'
    show NcmRouteObserver, modalRouteOpen, openPopups, pageDepth;

/// 最小可用的弹层路由(与 showModalBottomSheet/showDialog 同类: PopupRoute)。
class _TestPopupRoute<T> extends PopupRoute<T> {
  @override
  Color? get barrierColor => Colors.black54;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'popup';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const Center(child: Text('popup-body'));
}

Widget _page(String text) => Scaffold(body: Center(child: Text(text)));

/// 当前真的还挂在栈上的浮层(排除被替换掉的死 route)。
List<Route<dynamic>> livePopups() =>
    openPopups.where((r) => r.isActive).cast<Route<dynamic>>().toList();

void main() {
  // 两个 notifier 都是进程级静态量: 每个用例自己从干净状态起, 结束后还原。
  setUp(() {
    pageDepth.value = 0;
    modalRouteOpen.value = false;
  });
  tearDown(() {
    pageDepth.value = 0;
    modalRouteOpen.value = false;
  });

  testWidgets('全屏页被 pushReplacement 成弹层 ⇒ 层数 -1, 弹层入表', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [NcmRouteObserver()],
        home: _page('home'),
      ),
    );
    expect(pageDepth.value, 1, reason: '首页自己也会走 didPush');

    nav.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => _page('p1')),
    );
    await tester.pumpAndSettle();
    expect(pageDepth.value, 2);

    final popup = _TestPopupRoute<void>();
    nav.currentState!.pushReplacement(popup);
    await tester.pumpAndSettle();
    // 修复前: pageDepth 停在 2(底部导航消失), modalRouteOpen 还是 false。
    expect(pageDepth.value, 1, reason: '全屏层被弹层替掉, 层数必须减一');
    expect(modalRouteOpen.value, isTrue);
    expect(livePopups(), contains(popup));

    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isFalse);
    expect(pageDepth.value, 1);
  });

  testWidgets('弹层被 pushReplacement 成全屏页 ⇒ 弹层摘表, 层数 +1', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [NcmRouteObserver()],
        home: _page('home'),
      ),
    );

    final popup = _TestPopupRoute<void>();
    nav.currentState!.push(popup);
    await tester.pumpAndSettle();
    expect(modalRouteOpen.value, isTrue);
    expect(pageDepth.value, 1, reason: '弹层不参与层数');

    nav.currentState!.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => _page('p2')),
    );
    await tester.pumpAndSettle();
    // 修复前: modalRouteOpen 永久 true + 登记表里留着死 route, 层数也停在 1。
    expect(modalRouteOpen.value, isFalse);
    expect(livePopups(), isEmpty);
    expect(pageDepth.value, 2);

    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(pageDepth.value, 1);
  });

  testWidgets('全屏 ↔ 全屏 替换: 层数不变(不重复加一)', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        navigatorObservers: [NcmRouteObserver()],
        home: _page('home'),
      ),
    );
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => _page('a')));
    await tester.pumpAndSettle();
    expect(pageDepth.value, 2);

    for (var i = 0; i < 3; i++) {
      nav.currentState!.pushReplacement(
        MaterialPageRoute<void>(builder: (_) => _page('b$i')),
      );
      await tester.pumpAndSettle();
      expect(pageDepth.value, 2, reason: '替换不是新开一层');
    }
    expect(find.text('b2'), findsOneWidget);
  });
}
