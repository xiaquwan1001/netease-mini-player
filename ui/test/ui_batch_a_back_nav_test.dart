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
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));
  return calls;
}

/// HomePage 的 bootstrap 会去打平台通道/Rust(测试里必然失败 → 进错误态),
/// 同时启动 500ms 轮询 Timer, 所以只 pump 不 pumpAndSettle, 退出时把树换掉停 Timer.
Future<void> pumpHome(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(const MaterialApp(home: HomePage()));
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
    expect(calls, isNot(contains('SystemNavigator.pop')), reason: '收歌词不该退出 App');

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
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('推荐')),
      findsOneWidget,
    );

    final handled = await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(handled, isTrue);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('轻音 MiniNCM'),
      ),
      findsOneWidget,
      reason: '应回到搜索(首)tab',
    );
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
}
