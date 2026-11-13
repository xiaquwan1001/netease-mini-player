import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.Comment comment(int id, String content, {bool hot = false}) =>
    rust.Comment(
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
      hot: hot,
      parentId: BigInt.zero,
    );

rust.CommentPage page(List<rust.Comment> items) => rust.CommentPage(
  threadId: 'R_SO_4_1',
  comments: items,
  total: BigInt.from(items.length),
  hasMore: false,
);

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

/// 评论输入是"点开才出现"的面板(楼层回复面板里已有一个 TextField, 常驻会歧义)
Future<void> openComposer(WidgetTester tester) async {
  await tester.tap(find.text('写评论…'));
  await tester.pumpAndSettle();
}

FilledButton sendButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, '发送'));

void main() {
  testWidgets('空文本不可发送: 按钮禁用, 空白也不发', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => page([comment(1, '已有评论')]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page(const []),
          send: (commentId, content) async {
            sent.add('$commentId:$content');
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await openComposer(tester);
    expect(find.byType(TextField), findsOneWidget);
    expect(sendButton(tester).onPressed, isNull, reason: '空文本不能发');

    // 只有空白字符也不算内容
    await tester.enterText(find.byType(TextField), '    ');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNull);

    await tester.tap(
      find.widgetWithText(FilledButton, '发送'),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(find.text('已有评论'), findsOneWidget);
  });

  testWidgets('发送成功: 本地插入新评论(无头像 / "刚刚"), 面板关闭', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '热评', hot: true), comment(2, '最新评论')]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page(const []),
          send: (commentId, content) async {
            sent.add('$commentId:$content');
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await openComposer(tester);
    await tester.enterText(find.byType(TextField), '我的新评论');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();

    // 顶层评论复用 reply 链路: commentId = 0
    expect(sent, ['0:我的新评论']);
    expect(find.byType(TextField), findsNothing, reason: '发送成功后关闭输入面板');
    expect(find.text('我的新评论'), findsOneWidget);
    expect(find.text('刚刚'), findsOneWidget, reason: '无服务端时间时显示乐观态"刚刚"');
    expect(find.text('我'), findsOneWidget, reason: '乐观项昵称');
    // 乐观项 id=0, 不给删除入口
    expect(find.text('删除'), findsNothing);
    // 总数 +1(header 显示 3)
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('发送失败: 显示错误文案 + 保留文本, 重试成功后插入', (tester) async {
    var calls = 0;
    final sent = <String>[];
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => page([comment(1, '已有评论')]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page(const []),
          send: (commentId, content) async {
            calls++;
            if (calls == 1) throw Exception('boom');
            sent.add('$commentId:$content');
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await openComposer(tester);
    await tester.enterText(find.byType(TextField), '失败的评论');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('boom'),
      findsOneWidget,
      reason: 'friendlyError 文案',
    );
    // 文本保留在输入框里, 面板没关
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '失败的评论',
    );
    // 乐观项已回滚: 列表里没有这条评论, 总数回到 1
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsNothing);

    // 重试(同一个按钮)
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(sent, ['0:失败的评论']);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('失败的评论'), findsOneWidget);
  });

  testWidgets('键盘弹出(viewInsets)时输入框不被遮挡', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);

    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => page([comment(1, '已有评论')]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page(const []),
          send: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await openComposer(tester);
    // 键盘占 300dp, 可视区底部在 800 - 300 = 500
    const keyboardTop = 500.0;
    final field = tester.getRect(find.byType(TextField));
    expect(field.bottom, lessThanOrEqualTo(keyboardTop), reason: '输入框不能被键盘压住');
    final button = tester.getRect(find.widgetWithText(FilledButton, '发送'));
    expect(button.bottom, lessThanOrEqualTo(keyboardTop), reason: '发送按钮同样要能点到');
  });
}
