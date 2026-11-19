// U-08 回归: 真壳(MiniNcmApp)首帧不许「setState() called during build」。
//
// 背景(arch-audit-ui-overlay-2026-11-18 登记, 2026-11-19 落表 U-08):
// 壳层的 `ContentWidthLimit` 是 `LayoutBuilder`, 于是 Navigator(MaterialApp.home =
// HomePage)的**首次建树发生在 layout 阶段**; 而 `HomePage.initState` 会同步写
// `actionsHost` 槽位 ⇒ `MaterialApp.builder` 里的 `ValueListenableBuilder` 在
// 构建期被标脏 ⇒ 断言 `setState() or markNeedsBuild() called during build`。
// 生产同形(宽档/窄档都有: LayoutBuilder 总在 layout 里跑), 只是不炸给人看。
//
// 修法(`src/home/home_wiring.dart`): 两个 ValueNotifier 槽位(动作宿主 / 播放条回调)
// 一律**帧后投递**, `_clearSlots` 对称地帧后再清(dispose 也可能发生在 build 里)。
// 下面两条用例: 把 `_installSlots` 里的 `actionsHost.value = ...` 挪回同步写, 必红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart' show MiniNcmApp;
import 'package:minincm/src/app_shell.dart'
    show actionsHost, pageDepth, playerBarActions;

/// 真壳 pump: 不 mock Rust(init 失败进错误态即可, 本用例只关心首帧时序),
/// bootstrap 会起 500ms 轮询 Timer, 所以只 pump 固定帧数, **不用 pumpAndSettle**。
Future<void> _pumpShell(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const MiniNcmApp());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

void main() {
  setUp(() {
    actionsHost.value = null;
    playerBarActions.value = null;
    pageDepth.value = 0;
  });

  tearDown(() {
    // 静态槽位别留给下一个文件
    actionsHost.value = null;
    playerBarActions.value = null;
  });

  testWidgets('宽档 1280x720: 首帧无「during build」断言, 槽位帧后到位', (tester) async {
    await _pumpShell(tester, const Size(1280, 720));

    expect(tester.takeException(), isNull);
    // 帧后投递真的执行了(否则「...」动作菜单与播放条回调会永久失效)
    expect(actionsHost.value, isNotNull, reason: '动作宿主槽位必须帧后装上');
    expect(playerBarActions.value, isNotNull, reason: '播放条回调槽位必须帧后装上');
    // 根导航观察者确实挂上了(home 这条路由自己 didPush 过)
    expect(pageDepth.value, 1);
  });

  testWidgets('窄档 360x800: 同样无断言(限宽盒总在 layout 里跑)', (tester) async {
    await _pumpShell(tester, const Size(360, 800));

    expect(tester.takeException(), isNull);
    expect(actionsHost.value, isNotNull);
  });
}
