// 桌面(Linux/Windows)键盘返回: Esc = 退一层(2026-11-26 Linux 交互审查)。
//
// 口径:
//   · 栈顶是二级页 ⇒ Esc pop 它(与 AppBar 返回箭头同一条路);
//   · 栈顶是首页 ⇒ 交给首页的 PopScope(与 Android 返回键逐字节同一套优先级:
//     歌词 → 右栏 → tab → 歌单浏览态), 本层不复制判定;
//   · 焦点在文本输入里 ⇒ 只收焦点, 绝不退页面(搜索框里按 Esc 不该把页退掉);
//   · 非桌面平台(Esc 由 optimize 掉)⇒ 完全无反应。
//
// handler 挂在 HardwareKeyboard 上(不是 Shortcuts): 页面无焦点节点时 Esc 也要能退。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/desktop_escape_back.dart';
import 'package:minincm/src/player_bar.dart' show debugForceNonDesktopPlatform;

const Key kHomeKey = Key('escape-home');
const Key kPushedKey = Key('escape-pushed');

/// 与生产同形: MiniNcmApp.builder 里包一层 DesktopEscapeBack(它在 Navigator 之上)。
Future<GlobalKey<NavigatorState>> pumpApp(
  WidgetTester tester, {
  required Widget home,
}) async {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      builder: (context, child) =>
          DesktopEscapeBack(navigatorKey: navKey, child: child!),
      home: home,
    ),
  );
  await tester.pump();
  return navKey;
}

Future<void> pushPage(
  WidgetTester tester,
  GlobalKey<NavigatorState> navKey,
) async {
  navKey.currentState!.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => const Scaffold(key: kPushedKey, body: Text('二级页')),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => debugForceNonDesktopPlatform = false);

  testWidgets('桌面: Esc 退掉栈顶二级页', (tester) async {
    final navKey = await pumpApp(
      tester,
      home: const Scaffold(key: kHomeKey, body: Text('首页')),
    );
    await pushPage(tester, navKey);
    expect(find.byKey(kPushedKey), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byKey(kPushedKey), findsNothing, reason: 'Esc 应 pop 栈顶的二级页');
    expect(find.byKey(kHomeKey), findsOneWidget);
  });

  testWidgets('桌面: 首页上按 Esc 交给 PopScope(不复制返回优先级, 也不退掉根路由)', (tester) async {
    var backCalls = 0;
    final navKey = await pumpApp(
      tester,
      home: PopScope<void>(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) backCalls += 1;
        },
        child: const Scaffold(key: kHomeKey, body: Text('首页')),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(backCalls, 1, reason: 'Esc 要让首页的 PopScope 接到一次返回(与 Android 返回键同路)');
    expect(find.byKey(kHomeKey), findsOneWidget, reason: '根路由不许被 Esc 弹掉(会白屏)');
    expect(navKey.currentState!.canPop(), isFalse);
  });

  testWidgets('桌面: 焦点在文本输入里 ⇒ 只收焦点, 不退页面', (tester) async {
    final navKey = await pumpApp(
      tester,
      home: const Scaffold(key: kHomeKey, body: Text('首页')),
    );
    navKey.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(
          key: kPushedKey,
          body: Center(child: TextField(autofocus: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus ??
          true,
      isTrue,
      reason: 'autofocus 的输入框应拿到焦点',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.byKey(kPushedKey),
      findsOneWidget,
      reason: '搜索/筛选框里按 Esc 不许退页面',
    );
    final focus = FocusManager.instance.primaryFocus;
    expect(
      escapeTargetsTextInput(focus),
      isFalse,
      reason: 'Esc 应先把焦点从输入框里收走(下一次 Esc 才退页面)',
    );
  });

  testWidgets('非桌面(debugForceNonDesktopPlatform): Esc 完全无反应', (tester) async {
    debugForceNonDesktopPlatform = true;
    final navKey = await pumpApp(
      tester,
      home: const Scaffold(key: kHomeKey, body: Text('首页')),
    );
    await pushPage(tester, navKey);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
      find.byKey(kPushedKey),
      findsOneWidget,
      reason: '手机上的返回由系统返回键负责, 桌面 handler 不该插手',
    );
  });
}
