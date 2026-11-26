// 桌面(Linux/Windows)全局键盘: Esc 退一层 / 空格 播放暂停 / Ctrl+F 或 `/` 聚焦搜索
// (2026-11-26 Linux 交互审查; 空格与搜索快捷键由用户 2026-11-26 拍板)。
//
// 口径:
//   · Esc: 栈顶是二级页 ⇒ pop; 栈顶是首页 ⇒ 交给首页的 PopScope(与安卓返回键逐字节
//     同一套优先级: 歌词 → 右栏 → tab → 歌单浏览态), 本层不复制判定;
//   · 空格: 只调"播放/暂停", **不拿来翻页**(列表不会因为空格滚一屏); 没有播放器
//     (回调为 null)时不吃键, 搜索/筛选框里是普通字符;
//   · Ctrl+F / `/`: 聚焦搜索; `/` 在文本框里不拦, Ctrl+F 在文本框里仍然生效;
//   · 非桌面平台: 完全不挂 handler。
//
// handler 挂在 HardwareKeyboard 上(不是 Shortcuts): 页面无焦点节点时也要能响应。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/desktop_keys.dart';
import 'package:minincm/src/player_bar.dart' show debugForceNonDesktopPlatform;

const Key kHomeKey = Key('keys-home');
const Key kPushedKey = Key('keys-pushed');

/// 与生产同形: MiniNcmApp.builder 里包一层 DesktopKeys(它在 Navigator 之上)。
Future<GlobalKey<NavigatorState>> pumpApp(
  WidgetTester tester, {
  required Widget home,
  VoidCallback? Function()? togglePlayback,
  VoidCallback? Function()? focusSearch,
}) async {
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navKey,
      builder: (context, child) => DesktopKeys(
        navigatorKey: navKey,
        togglePlayback: togglePlayback,
        focusSearch: focusSearch,
        child: child!,
      ),
      home: home,
    ),
  );
  await tester.pump();
  return navKey;
}

Future<void> pushPage(
  WidgetTester tester,
  GlobalKey<NavigatorState> navKey, {
  Widget? page,
}) async {
  navKey.currentState!.push<void>(
    MaterialPageRoute<void>(
      builder: (_) =>
          page ?? const Scaffold(key: kPushedKey, body: Text('二级页')),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> pressCtrlF(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => debugForceNonDesktopPlatform = false);

  group('Esc', () {
    testWidgets('退掉栈顶二级页', (tester) async {
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

    testWidgets('首页上交给 PopScope(不复制返回优先级, 也不退掉根路由)', (tester) async {
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

      expect(backCalls, 1, reason: 'Esc 要让首页的 PopScope 接到一次返回(与安卓返回键同路)');
      expect(
        find.byKey(kHomeKey),
        findsOneWidget,
        reason: '根路由不许被 Esc 弹掉(会白屏)',
      );
      expect(navKey.currentState!.canPop(), isFalse);
    });

    testWidgets('焦点在文本输入里 ⇒ 只收焦点, 不退页面', (tester) async {
      final navKey = await pumpApp(
        tester,
        home: const Scaffold(key: kHomeKey, body: Text('首页')),
      );
      await pushPage(
        tester,
        navKey,
        page: const Scaffold(
          key: kPushedKey,
          body: Center(child: TextField(autofocus: true)),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        find.byKey(kPushedKey),
        findsOneWidget,
        reason: '搜索/筛选框里按 Esc 不许退页面',
      );
      expect(
        escapeTargetsTextInput(FocusManager.instance.primaryFocus),
        isFalse,
        reason: 'Esc 应先把焦点从输入框里收走(下一次 Esc 才退页面)',
      );
    });
  });

  group('空格 = 播放/暂停(不翻页)', () {
    testWidgets('吃掉空格并调播放回调', (tester) async {
      var toggles = 0;
      await pumpApp(
        tester,
        home: const Scaffold(key: kHomeKey, body: Text('首页')),
        togglePlayback: () =>
            () => toggles += 1,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(toggles, 1);
    });

    testWidgets('没有可切换的播放器(回调 null)⇒ 不吃键', (tester) async {
      await pumpApp(
        tester,
        home: const Scaffold(key: kHomeKey, body: Text('首页')),
        togglePlayback: () => null,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      // 没有被消费的证据: 根路由依然在, 且没有异常(键给了下面的滚动/按钮)
      expect(find.byKey(kHomeKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('文本框里空格是普通字符, 不切歌', (tester) async {
      var toggles = 0;
      await pumpApp(
        tester,
        home: const Scaffold(
          key: kHomeKey,
          body: Center(child: TextField(autofocus: true)),
        ),
        togglePlayback: () =>
            () => toggles += 1,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(toggles, 0, reason: '输入框里按空格必须能打空格');
    });
  });

  group('Ctrl+F / `/` = 聚焦搜索', () {
    testWidgets('Ctrl+F 生效', (tester) async {
      var focused = 0;
      await pumpApp(
        tester,
        home: const Scaffold(key: kHomeKey, body: Text('首页')),
        focusSearch: () =>
            () => focused += 1,
      );

      await pressCtrlF(tester);

      expect(focused, 1);
    });

    testWidgets('`/` 生效; 文本框里的 `/` 不拦', (tester) async {
      var focused = 0;
      final navKey = await pumpApp(
        tester,
        home: const Scaffold(key: kHomeKey, body: Text('首页')),
        focusSearch: () =>
            () => focused += 1,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();
      expect(focused, 1);

      // 输入框里再按 `/`: 应该打字符而不是"聚焦搜索"
      navKey.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            key: kPushedKey,
            body: Center(child: TextField(autofocus: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.slash);
      await tester.pumpAndSettle();

      expect(focused, 1, reason: '文本框里的 `/` 是普通字符, 不许触发聚焦搜索');
    });
  });

  testWidgets('非桌面(debugForceNonDesktopPlatform): 三条键都不接管', (tester) async {
    debugForceNonDesktopPlatform = true;
    var toggles = 0;
    var focused = 0;
    final navKey = await pumpApp(
      tester,
      home: const Scaffold(key: kHomeKey, body: Text('首页')),
      togglePlayback: () =>
          () => toggles += 1,
      focusSearch: () =>
          () => focused += 1,
    );
    await pushPage(tester, navKey);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await pressCtrlF(tester);

    expect(find.byKey(kPushedKey), findsOneWidget, reason: '手机上的返回由系统返回键负责');
    expect(toggles, 0);
    expect(focused, 0);
  });
}
