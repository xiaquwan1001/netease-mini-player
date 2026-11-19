// 主从分栏(方案 B · S4)的入口与几何回归。
//
// 口径(见 lib/src/detail_pane.dart 与 lib/src/layout.dart 的「主从分栏」常量):
//   · openDetail 三条否决: 宿主不在场 / 调用者不在根路由 / 窗口不满足 twoColumnFor
//     ⇒ 任一成立就走 push 一整页(窄档语义);
//   · 右栏**不是路由**: 槽位变化不碰 Navigator, pageDepth 不动(=1), 浮层登记面不变;
//   · 几何: 壳层 840 = 左 408 / 间距 12 / 右 420(kDetailPaneWidth)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_shell.dart' show NcmRouteObserver, pageDepth;
import 'package:minincm/src/detail_pane.dart';
import 'package:minincm/src/layout.dart';

const Key _paneBody = Key('pane-body');
const Key _fullPage = Key('full-page');

/// 打开详情(宽档 ⇒ 右栏; 否则 push)—— 与歌单详情同一个入口形态。
Future<void> _open(BuildContext context, {Object key = 'pl-1'}) => openDetail(
  context,
  key: key,
  pane: (_) => const Text('右栏内容', key: _paneBody),
  route: () => MaterialPageRoute<void>(
    builder: (_) => Scaffold(
      key: _fullPage,
      appBar: AppBar(title: const Text('全屏详情')),
      body: const Text('全屏详情体'),
    ),
  ),
);

/// 左栏宿主: 与 HomePage 同一条装配(登记宿主 + [DetailPaneSplit] 当左栏)。
class _SplitHost extends StatefulWidget {
  const _SplitHost({this.register = true});

  /// false = 模拟"没有右栏宿主"的页面(歌单详情自己的双列测试/golden 就是这种树)。
  final bool register;

  @override
  State<_SplitHost> createState() => _SplitHostState();
}

class _SplitHostState extends State<_SplitHost> {
  @override
  void initState() {
    super.initState();
    if (widget.register) attachDetailPaneHost();
  }

  @override
  void dispose() {
    if (widget.register) detachDetailPaneHost();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        Row(
          children: [
            TextButton(
              onPressed: () => _open(context),
              child: const Text('打开详情'),
            ),
            TextButton(
              onPressed: () => _open(context, key: 'pl-2'),
              child: const Text('打开另一条'),
            ),
          ],
        ),
        Expanded(
          child: DetailPaneSplit(
            master: (context, selectedKey) => Center(
              child: Text(selectedKey == null ? '列表' : '列表(选中 $selectedKey)'),
            ),
          ),
        ),
      ],
    ),
  );
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required Size size,
  bool register = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      navigatorObservers: [NcmRouteObserver()],
      builder: (context, child) =>
          ContentWidthLimit(child: child ?? const SizedBox.shrink()),
      home: _SplitHost(register: register),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    // 壳层的栈计数是全局静态量: 上一个用例的树被直接换掉, didPop 不会来
    pageDepth.value = 0;
    detailPaneSlot.value = null;
  });

  testWidgets('1280x720 + 宿主 + 根路由 ⇒ 只填右栏, 不 push 页面', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720));
    expect(pageDepth.value, 1);

    await tester.tap(find.text('打开详情'));
    await tester.pump();

    expect(detailPaneSlot.value, isNotNull);
    expect(detailPaneSlot.value!.key, 'pl-1');
    expect(find.byKey(_paneBody), findsOneWidget);
    expect(find.byKey(_fullPage), findsNothing, reason: '宽档不该 push 一整页');
    expect(pageDepth.value, 1, reason: '右栏不是路由, 页面层数不变');
    expect(find.text('列表(选中 pl-1)'), findsOneWidget, reason: '左栏仍在且知道选中哪条');
    expect(find.text('打开详情'), findsOneWidget, reason: '左栏的工具条也还在');
  });

  testWidgets('1280x720: 换一条详情 ⇒ 槽位换 key, 左栏选中态跟着变', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720));
    await tester.tap(find.text('打开详情'));
    await tester.pump();
    await tester.tap(find.text('打开另一条'));
    await tester.pump();

    expect(detailPaneSlot.value!.key, 'pl-2');
    expect(find.text('列表(选中 pl-2)'), findsOneWidget);
  });

  testWidgets('360x800(窄档) ⇒ 照旧 push 一整页, 右栏不参与', (tester) async {
    await _pumpHost(tester, size: const Size(360, 800));

    await tester.tap(find.text('打开详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(detailPaneSlot.value, isNull, reason: '窄档必须走 push');
    expect(find.byKey(_fullPage), findsOneWidget);
    expect(find.text('全屏详情体'), findsOneWidget);
    expect(pageDepth.value, 2, reason: '窄档的详情是真正的一层路由');
  });

  testWidgets('宽档但没有右栏宿主 ⇒ 仍 push(歌单详情自己的双列测试/golden 走这条)', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720), register: false);

    await tester.tap(find.text('打开详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(detailPaneSlot.value, isNull);
    expect(find.byKey(_fullPage), findsOneWidget);
    expect(pageDepth.value, 2);
  });

  testWidgets('宽档 + 宿主, 但调用者在压上来的全屏页里 ⇒ 仍 push', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720));
    final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
    nav.push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('压上来的页')),
          body: TextButton(
            onPressed: () => _open(context),
            child: const Text('页内打开详情'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('页内打开详情'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(detailPaneSlot.value, isNull, reason: '右栏在下面那层(看不见), 不能往那里塞详情');
    expect(find.byKey(_fullPage), findsOneWidget);
    expect(pageDepth.value, 3);
  });

  testWidgets('几何: 840 切成 左 408 / 间距 12 / 右 420, 且填满内容区', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720));
    await tester.tap(find.text('打开详情'));
    await tester.pump();

    final split = tester.getRect(find.byType(DetailPaneSplit));
    final pane = tester.getRect(find.byType(DetailPaneSurface));
    final contentLeft = (1280 - kContentMaxWidth) / 2;
    final masterRight =
        contentLeft + kContentMaxWidth - kDetailPaneWidth - kTwoColumnGap;

    expect(split.left, contentLeft, reason: '内容区左边 = 壳层居中留白后');
    expect(split.width, kContentMaxWidth, reason: '主从分栏仍住在 840 内容区里');
    expect(pane.width, kDetailPaneWidth, reason: '右栏固定 420');
    expect(pane.right, contentLeft + kContentMaxWidth, reason: '右栏右边 = 内容区右边');
    expect(pane.left - masterRight, kTwoColumnGap, reason: '左栏与右栏之间正好 12');
    expect(
      kContentMaxWidth - kDetailPaneWidth - kTwoColumnGap,
      408,
      reason: '左栏 = 408',
    );
  });

  testWidgets('右栏关闭后左栏恢复整宽(几何回到改动前)', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720));
    await tester.tap(find.text('打开详情'));
    await tester.pump();
    expect(find.byType(DetailPaneSurface), findsOneWidget);

    closeDetailPane();
    await tester.pump();

    expect(find.byType(DetailPaneSurface), findsNothing);
    expect(find.text('列表'), findsOneWidget, reason: '选中态一并撤掉');
    expect(
      tester.getRect(find.byType(DetailPaneSplit)).width,
      kContentMaxWidth,
    );
  });

  testWidgets('宽档缩到窄档 ⇒ 右栏帧后自动关闭(不留下放不下的详情)', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720));
    await tester.tap(find.text('打开详情'));
    await tester.pump();
    expect(detailPaneSlot.value, isNotNull);

    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    await tester.pump();

    expect(detailPaneSlot.value, isNull, reason: '右栏放不下就该关掉, 下次点走 push');
    expect(find.byType(DetailPaneSurface), findsNothing);
  });

  testWidgets('closeDetailPane: 有关才返回 true(幂等)', (tester) async {
    await _pumpHost(tester, size: const Size(1280, 720));
    expect(closeDetailPane(), isFalse);
    await tester.tap(find.text('打开详情'));
    await tester.pump();
    expect(closeDetailPane(), isTrue);
    expect(closeDetailPane(), isFalse);
    expect(detailPaneSlot.value, isNull);
  });
}
