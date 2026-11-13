import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/main.dart';

/// 记录 SystemNavigator.pop(「交还系统退出」)是否被调用
List<String> recordSystemCalls(WidgetTester tester) {
  final calls = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      calls.add(call.method);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return calls;
}

/// HomePage 的 bootstrap 会去打平台通道/Rust(测试里必然失败 → 进错误态),
/// 同时启动 500ms 轮询 Timer, 所以只 pump 不 pumpAndSettle, 退出时把树换掉停 Timer.
Future<void> pumpHome(
  WidgetTester tester, {
  Size size = const Size(1200, 2400),
  TextScaler? scaler,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  // 底部导航/播放条现在由根布局的 PlayerBarHost 渲染(见 main.dart),
  // 测试也走同一条壳, 否则 NavigationBar 不会出现。
  addTearDown(() => playerBarSlot.value = null);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) =>
          PlayerBarHost(content: child ?? const SizedBox.shrink()),
      home: MediaQuery(
        data: MediaQueryData(textScaler: scaler ?? TextScaler.noScaling),
        child: const HomePage(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
  addTearDown(() async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    } catch (_) {}
  });
}

/// 模拟 HomePage 里"歌词展开"这个二级态的最小宿主(歌词需要播放器才能进, 用状态机替身)
class LyricHarness extends StatefulWidget {
  const LyricHarness({super.key});

  @override
  State<LyricHarness> createState() => LyricHarnessState();
}

class LyricHarnessState extends State<LyricHarness> {
  bool lyrics = true;
  int backs = 0;

  @override
  Widget build(BuildContext context) {
    final action = resolveHomeBackAction(
      showLyrics: lyrics,
      tab: 0,
      libraryOpen: false,
    );
    return HomeBackGuard(
      action: action,
      onBack: () => setState(() {
        backs++;
        lyrics = false;
      }),
      child: Scaffold(
        appBar: AppBar(title: Text(lyrics ? '歌词' : '轻音 MiniNCM')),
        body: Text(lyrics ? '歌词页' : '搜索页'),
      ),
    );
  }
}

void main() {
  group('resolveHomeBackAction: 返回键优先级', () {
    test('歌词展开最优先, 与 tab/歌单态无关', () {
      expect(
        resolveHomeBackAction(showLyrics: true, tab: 3, libraryOpen: true),
        HomeBackAction.collapseLyrics,
      );
    });

    test('非首 tab 其次', () {
      expect(
        resolveHomeBackAction(showLyrics: false, tab: 2, libraryOpen: true),
        HomeBackAction.resetTab,
      );
    });

    test('首 tab 的歌单浏览态再次', () {
      expect(
        resolveHomeBackAction(showLyrics: false, tab: 0, libraryOpen: true),
        HomeBackAction.closeLibrary,
      );
    });

    test('都没有才交还系统退出', () {
      expect(
        resolveHomeBackAction(showLyrics: false, tab: 0, libraryOpen: false),
        HomeBackAction.exitApp,
      );
    });
  });

  testWidgets('歌词展开态按返回 → 先收歌词, 不退出 App', (tester) async {
    final calls = recordSystemCalls(tester);
    await tester.pumpWidget(const MaterialApp(home: LyricHarness()));

    expect(find.text('歌词页'), findsOneWidget);
    final state = tester.state<LyricHarnessState>(find.byType(LyricHarness));
    final handled = await tester.binding.handlePopRoute();
    await tester.pump();

    expect(handled, isTrue);
    expect(state.lyrics, isFalse);
    expect(state.backs, 1);
    expect(find.text('搜索页'), findsOneWidget);
    expect(
      calls,
      isNot(contains('SystemNavigator.pop')),
      reason: '收歌词不该退出 App',
    );

    // 二级态退干净后再按一次才交还系统
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(calls, contains('SystemNavigator.pop'));
  });

  testWidgets('非首 tab 按返回 → 回首个 tab(不退出 App)', (tester) async {
    final calls = recordSystemCalls(tester);
    await pumpHome(tester);

    await tester.tap(find.text('推荐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 2026-11-09: 顶部栏不再重复底部导航的关键词 —— 非首 tab 干脆没有 AppBar, 高度让给内容
    expect(find.byType(AppBar), findsNothing);
    final navOnRecommend = tester.widget<NavigationBar>(
      find.byType(NavigationBar),
    );
    expect(navOnRecommend.selectedIndex, 1);

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(handled, isTrue);
    // 2026-11-09: 首 tab 也去掉了顶部品牌横幅, 所以"回到搜索"的判据用导航选中态
    expect(find.byType(AppBar), findsNothing, reason: '搜索页没有顶部栏');
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar.selectedIndex, 0);
    expect(calls, isNot(contains('SystemNavigator.pop')));
  });

  testWidgets('首 tab 无二级态按返回 → 交还系统退出', (tester) async {
    final calls = recordSystemCalls(tester);
    await pumpHome(tester);

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(handled, isFalse, reason: '栈底无二级态 = 交给系统');
    expect(calls, contains('SystemNavigator.pop'));
    expect(find.byType(HomePage), findsOneWidget, reason: 'Dart 侧不该自己 pop 根路由');
  });

  testWidgets('300dp + 1.25 字号: 首页壳不溢出, 栈底返回仍交还系统', (tester) async {
    final calls = recordSystemCalls(tester);
    await pumpHome(
      tester,
      size: const Size(300, 640),
      scaler: const TextScaler.linear(1.25),
    );
    expect(tester.takeException(), isNull);

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(handled, isFalse, reason: '栈底无二级态 = 交给系统');
    expect(calls, contains('SystemNavigator.pop'));
  });
}
