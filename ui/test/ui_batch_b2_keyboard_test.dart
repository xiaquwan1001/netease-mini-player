import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/detail_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.CommentDto comment(int id, String content) => rust.CommentDto(
  id: BigInt.from(id),
  userId: BigInt.from(100 + id),
  userName: '用户$id',
  avatarUrl: null,
  content: content,
  timeMs: BigInt.from(1700000000000),
  likedCount: BigInt.zero,
  liked: false,
  replyCount: BigInt.zero,
  ipLocation: '',
  hot: false,
);

rust.CommentPageDto page(List<rust.CommentDto> items) => rust.CommentPageDto(
  threadId: 'R_SO_4_1',
  comments: items,
  total: BigInt.from(items.length),
  hasMore: false,
);

Widget host() => MaterialApp(
  home: Scaffold(
    body: Center(
      child: Builder(
        builder: (context) => FilledButton(
          onPressed: () => showCommentsSheet(
            context,
            kind: 'song',
            resourceId: BigInt.one,
            loadPage: (limit, offset) async =>
                page(List.generate(12, (i) => comment(i + 1, '评论${i + 1}'))),
            like: (_, _) async => true,
            loadReplies: (_, _) async => page(const []),
            send: (_, _) async => true,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> openSheet(WidgetTester tester) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);

  await tester.pumpWidget(host());
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 弹层根节点的键盘避让 Padding
EdgeInsets sheetPadding(WidgetTester tester) =>
    tester.widget<Padding>(find.byKey(const ValueKey('b2-sheet-root'))).padding
        as EdgeInsets;

void main() {
  testWidgets('键盘弹出时根节点有 viewInsets.bottom padding, 面板高度被压掉', (tester) async {
    await openSheet(tester);
    // 无键盘: 无底部 padding
    expect(sheetPadding(tester).bottom, 0.0);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    final p = sheetPadding(tester);
    expect(p.bottom, 300.0, reason: '根节点要按键盘高度抬升');

    // 面板高度: 800 * 0.75 - 300 = 300(不低于 200 下限)
    final box = tester.getRect(find.byType(SafeArea).first);
    expect(box.height, closeTo(300, 0.5));
    // 抬升后弹层底部贴着键盘顶(800 - 300)
    expect(box.bottom, closeTo(500, 0.5), reason: '弹层整体要坐在键盘上');
  });

  testWidgets('键盘弹出时输入框仍可见且在可视区内', (tester) async {
    await openSheet(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    // 输入入口在列表底部: 键盘弹出后先确保它滚进可视区再点开
    await tester.ensureVisible(find.text('写评论…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写评论…'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    const keyboardTop = 500.0;
    final field = tester.getRect(find.byType(TextField));
    expect(field.bottom, lessThanOrEqualTo(keyboardTop), reason: '输入框不能被键盘压住');
    expect(field.top, greaterThanOrEqualTo(0.0));
    final send = tester.getRect(find.widgetWithText(FilledButton, '发送'));
    expect(send.bottom, lessThanOrEqualTo(keyboardTop), reason: '发送按钮可点');
  });

  testWidgets('键盘弹出时列表可滚动到最新评论', (tester) async {
    await openSheet(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();

    // 最新评论在列表尾部, 要能滚到它
    await tester.scrollUntilVisible(
      find.text('评论12'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('评论12'), findsOneWidget);
  });

  testWidgets('键盘收起后无多余底部空白: padding 归零, 弹层回到底部', (tester) async {
    await openSheet(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    expect(sheetPadding(tester).bottom, 300.0);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();

    expect(sheetPadding(tester).bottom, 0.0, reason: '不留白');
    final box = tester.getRect(find.byType(SafeArea).first);
    expect(box.height, closeTo(600, 0.5), reason: '高度回弹到 75%');
    expect(box.bottom, closeTo(800, 0.5), reason: '弹层回贴屏幕底部');
  });
}
