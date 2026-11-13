import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/feed_detail_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

/// 动态详情页「评论」按钮回归: 点它必须「去写评论」(滚到评论区 + 打开
/// 写评论面板聚焦输入框), 不能把详情页 pop 掉(曾经误写成 Navigator.pop)。

rust.FeedEventDto event({bool withThread = true}) => rust.FeedEventDto(
      id: BigInt.one,
      threadId: withThread ? 'A_EV_2_1_1' : '',
      userId: BigInt.one,
      kind: 'text',
      userName: '发动态的用户',
      text: '一条用于评论入口回归测试的动态正文',
      images: const [],
      title: '',
      timeMs: BigInt.from(1700000000000),
      liked: false,
      likedCount: BigInt.zero,
      shareCount: BigInt.zero,
      commentCount: BigInt.zero,
    );

Future<void> openDetail(
  WidgetTester tester, {
  bool withThread = true,
  bool narrow = false,
}) async {
  final ev = event(withThread: withThread);
  Widget page(BuildContext context) => TextButton(
        onPressed: () => showFeedDetail(
          context,
          event: ev,
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
        ),
        child: const Text('open'),
      );
  Widget tree = MaterialApp(home: Scaffold(body: Builder(builder: page)));
  if (narrow) {
    tree = MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
      child: tree,
    );
  }
  await tester.pumpWidget(tree);
  await tester.tap(find.text('open'));
  // 分步推进路由转场, 不用 pumpAndSettle(评论区加载失败后可能有重试定时器)
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('评论按钮: 不 pop 页面, 打开写评论面板并聚焦输入框', (tester) async {
    await openDetail(tester);
    expect(find.text('动态'), findsOneWidget); // 详情页 AppBar

    // 评论区加载失败(测试环境无 Rust)不影响入口: threadId 非空即可写评论
    await tester.tap(find.byIcon(Icons.mode_comment_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // 不 pop: 详情页 AppBar 与正文都还在
    expect(find.text('动态'), findsOneWidget);
    expect(find.text('一条用于评论入口回归测试的动态正文'), findsOneWidget);

    // 写评论面板已打开, 面板里的 TextField 拿到焦点(autofocus)
    expect(find.text('写评论'), findsOneWidget);
    final field = tester.widget<EditableText>(find.byType(EditableText).last);
    expect(field.focusNode.hasFocus, isTrue);
  });

  testWidgets('无评论区动态: 评论按钮保持禁用, 点击不弹面板也不退页', (tester) async {
    await openDetail(tester, withThread: false);
    expect(find.text('这条动态暂不支持评论'), findsOneWidget);

    final button = tester.widget<TextButton>(
      find
          .ancestor(
            of: find.byIcon(Icons.mode_comment_outlined),
            matching: find.byType(TextButton),
          )
          .first,
    );
    expect(button.onPressed, isNull); // 禁用态保持

    await tester.tap(find.byIcon(Icons.mode_comment_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('写评论'), findsNothing);
    expect(find.text('这条动态暂不支持评论'), findsOneWidget); // 页面未 pop
  });

  testWidgets('300dp + 1.25 字号: 详情页与写评论面板不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await openDetail(tester, narrow: true);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.mode_comment_outlined));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('写评论'), findsOneWidget);
  });
}
