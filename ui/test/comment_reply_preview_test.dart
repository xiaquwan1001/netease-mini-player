// 评论区楼层内联回复预览(方案与规则见 .pi/artifacts/comment-floor-inline.md)。
//
// 覆盖: 预览条数规则(互动优先) / 展开全部入口 / 点展开开面板 /
// 点回复进写回复 / 预览失败静默 / 窄屏+大字号不溢出 / 发回复后预览立现。
// 全部用分步 pump, 不用 pumpAndSettle 死等。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.Comment comment(
  int id,
  String content, {
  int likedCount = 0,
  int replyCount = 0,
  bool hot = false,
}) => rust.Comment(
  id: BigInt.from(id),
  userId: BigInt.from(100 + id),
  userName: '用户$id',
  avatarUrl: null,
  content: content,
  timeMs: BigInt.from(1700000000000 + id),
  likedCount: BigInt.from(likedCount),
  liked: false,
  replyCount: BigInt.from(replyCount),
  ipLocation: '',
  hot: hot,
  parentId: BigInt.zero,
);

rust.CommentPage page(
  List<rust.Comment> items, {
  String threadId = 'R_SO_4_1',
}) => rust.CommentPage(
  threadId: threadId,
  comments: items,
  total: BigInt.from(items.length),
  hasMore: false,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('预览: 回复 >3 条时行内展示点赞最高的 3 条, 其余靠展开入口', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: 5, likedCount: 10)]),
          loadReplies: (parentId, limit) async => page([
            comment(2, '赞少', likedCount: 1),
            comment(3, '赞多一', likedCount: 9),
            comment(4, '赞多二', likedCount: 8),
            comment(5, '赞中', likedCount: 5),
          ]),
          like: (_, _) async => true,
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pump(); // 首页到位 + 排队
    await tester.pump(); // 预览响应落地
    await tester.pump();

    expect(find.text('用户3：赞多一'), findsOneWidget);
    expect(find.text('用户4：赞多二'), findsOneWidget);
    expect(find.text('用户5：赞中'), findsOneWidget); // 第 3 名也算"主要回复"
    expect(find.text('用户2：赞少'), findsNothing); // 第 4 名不露
    expect(find.text('展开全部 5 条回复'), findsOneWidget);
  });

  testWidgets('预览: 回复 ≤3 条全部展示, 且不给「展开」按钮(冗余)', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: 2)]),
          loadReplies: (parentId, limit) async => page([
            comment(2, '回复甲', likedCount: 4),
            comment(3, '回复乙', likedCount: 4),
          ]),
          like: (_, _) async => true,
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('用户2：回复甲'), findsOneWidget);
    expect(find.text('用户3：回复乙'), findsOneWidget);
    expect(find.textContaining('展开全部'), findsNothing);
  });

  testWidgets('点预览里的某条回复 = 展开楼层详情(与写回复分离)', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: 5)]),
          loadReplies: (parentId, limit) async =>
              page([comment(2, '深层回复甲'), comment(3, '深层回复乙')]),
          like: (_, _) async => true,
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('用户2：深层回复甲'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 弹层进场动画

    // 面板头部是"用户名: 内容"摘要(面板专属标记), 且能看全量列表
    expect(find.text('用户1: 父评论'), findsOneWidget);
    expect(find.text('深层回复乙'), findsOneWidget);
  });

  testWidgets('「展开全部 N 条回复」入口: 独立可见, 点击打开楼层详情', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: 5)]),
          loadReplies: (parentId, limit) async =>
              page([comment(2, '深层回复甲'), comment(3, '深层回复乙')]),
          like: (_, _) async => true,
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.text('展开全部 5 条回复'), findsOneWidget);
    await tester.tap(find.text('展开全部 5 条回复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('用户1: 父评论'), findsOneWidget);
    expect(find.text('深层回复甲'), findsOneWidget);
    expect(find.text('深层回复乙'), findsOneWidget);
  });

  testWidgets('「回复」按钮: 直接打开面板并聚焦写回复输入框', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: 3)]),
          loadReplies: (parentId, limit) async =>
              page([comment(2, '旧回复', likedCount: 9)]),
          like: (_, _) async => true,
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('回复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('回复这条评论…'), findsOneWidget);
    // 直接进写回复: 输入框已获得焦点(浏览模式不抢焦点)
    final focusNode = tester
        .widget<EditableText>(find.byType(EditableText))
        .focusNode;
    expect(FocusManager.instance.primaryFocus, same(focusNode));
  });

  testWidgets('预览加载失败: 静默, 主列表与展开入口不受影响', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: 2)]),
          loadReplies: (parentId, limit) async =>
              throw Exception('preview boom'),
          like: (_, _) async => true,
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('父评论'), findsOneWidget);
    expect(find.text('展开全部 2 条回复'), findsOneWidget);
    expect(find.textContaining('用户2'), findsNothing);
  });

  testWidgets('发回复后: 预览立刻带上刚发的回复(发了看得见)', (tester) async {
    var replyCount = 1;
    final replies = <rust.Comment>[comment(2, '已有旧回复', likedCount: 5)];
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: replyCount)]),
          loadReplies: (parentId, limit) async => page(List.of(replies)),
          like: (_, _) async => true,
          reply: (commentId, content) async {
            replyCount++;
            replies.add(comment(3, '刚发的回复'));
            return true;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('用户2：已有旧回复'), findsOneWidget);

    await tester.tap(find.text('回复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), '刚发的回复');
    await tester.tap(find.text('发送'));
    // 发送链路: reply hook → 面板内重拉 → pop(true) → 外层 bump + 预览重拉
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    // ≤3 条: 全部缩进展示, 新旧都在, 不用再点「展开」
    expect(find.text('用户3：刚发的回复'), findsOneWidget);
    expect(find.text('用户2：已有旧回复'), findsOneWidget);
    expect(find.textContaining('展开全部'), findsNothing);
  });

  testWidgets('300dp + 1.25 字号: 预览行截断不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: CommentThread(
                kind: 'song',
                resourceId: BigInt.one,
                loadPage: (limit, offset) async => page([
                  comment(1, '这是一条非常长的父评论内容用来挤压行宽确认不会横向溢出', replyCount: 5),
                ]),
                loadReplies: (parentId, limit) async => page([
                  comment(2, '非常长的预览回复内容之一非常长的预览回复内容之一非常长', likedCount: 9),
                  comment(3, '非常长的预览回复内容之二非常长的预览回复内容之二非常长', likedCount: 8),
                  comment(4, '短回复', likedCount: 1),
                ]),
                like: (_, _) async => true,
                reply: (_, _) async => true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text('展开全部 5 条回复'), findsOneWidget);
  });
}
