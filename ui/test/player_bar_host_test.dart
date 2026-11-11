// 常驻播放条(PlayerBarHost): 二级路由压上来播放条仍在, 只有键盘弹出时让位.
//
// 背景: 播放条原先在 HomePage.bottomNavigationBar 里, 日推"全部"等二级页一压上来
// 就没了; 现在由 MaterialApp.builder 的 PlayerBarHost 渲染在 Navigator 之下.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';

Widget _app({double keyboardInset = 0}) {
  return MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(viewInsets: EdgeInsets.only(bottom: keyboardInset)),
      child: PlayerBarHost(content: child ?? const SizedBox.shrink()),
    ),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('二级页')),
            ),
          ),
          child: const Text('进二级页'),
        ),
      ),
    ),
  );
}

void main() {
  tearDown(() => playerBarSlot.value = null);

  testWidgets('二级路由压上来: 播放条仍然在场(且没被二级页盖住)', (tester) async {
    playerBarSlot.value = const Text('播放条替身');
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('播放条替身'), findsOneWidget);

    await tester.tap(find.text('进二级页'));
    await tester.pumpAndSettle();
    expect(find.text('二级页'), findsOneWidget);
    expect(find.text('播放条替身'), findsOneWidget,
        reason: '二级页(日推全部/歌单广场等)压上来后播放条不该消失');

    // 退回首页也还在
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.text('播放条替身'), findsOneWidget);
  });

  testWidgets('键盘弹出: 播放条让位(不占内容高度)', (tester) async {
    playerBarSlot.value = const Text('播放条替身');
    await tester.pumpWidget(_app(keyboardInset: 320));
    await tester.pumpAndSettle();
    expect(find.text('播放条替身'), findsNothing);
  });

  testWidgets('没有曲目(槽位为空): 底部条不占位置', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('进二级页'), findsOneWidget);
    final scaffoldBox = tester.getSize(find.byType(Scaffold));
    // 首页 Scaffold 拿到屏幕的全高(Navigator 区域 = 整屏)
    expect(scaffoldBox.height, tester.view.physicalSize.height / tester.view.devicePixelRatio);
  });
}
