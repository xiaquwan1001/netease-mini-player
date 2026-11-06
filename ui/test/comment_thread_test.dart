import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.CommentDto comment(
  int id,
  String content, {
  int likedCount = 0,
  bool liked = false,
  int replyCount = 0,
}) =>
    rust.CommentDto(
      id: BigInt.from(id),
      userId: BigInt.from(100 + id),
      userName: '用户$id',
      avatarUrl: null,
      content: content,
      timeMs: BigInt.from(1700000000000),
      likedCount: BigInt.from(likedCount),
      liked: liked,
      replyCount: BigInt.from(replyCount),
    );

rust.CommentPageDto page(List<rust.CommentDto> items,
        {String threadId = 'R_SO_4_1'}) =>
    rust.CommentPageDto(
      threadId: threadId,
      comments: items,
      total: BigInt.from(items.length),
      hasMore: false,
    );

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('评论列表: 点赞本地翻转 + 回调, 回复数展示', (tester) async {
    final liked = <String>[];
    await tester.pumpWidget(host(CommentThread(
      kind: 'song',
      resourceId: BigInt.one,
      loadPage: (limit, offset) async =>
          page([comment(1, '好听', likedCount: 3, replyCount: 2)]),
      like: (commentId, value) async {
        liked.add('$commentId:$value');
        return true;
      },
      loadReplies: (parentId, limit) async => page([]),
      reply: (commentId, content) async => true,
    )));
    await tester.pumpAndSettle();

    expect(find.text('好听'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('回复 2'), findsOneWidget);

    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    expect(liked, ['1:true']);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('楼层: 打开回复列表并发回复', (tester) async {
    final sent = <String>[];
    var repliesLoaded = 0;
    await tester.pumpWidget(host(CommentThread(
      kind: 'song',
      resourceId: BigInt.one,
      loadPage: (limit, offset) async =>
          page([comment(1, '父评论', replyCount: 1)]),
      like: (_, _) async => true,
      loadReplies: (parentId, limit) async {
        repliesLoaded++;
        return page([comment(2, '已有回复')]);
      },
      reply: (commentId, content) async {
        sent.add('$commentId:$content');
        return true;
      },
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('回复 1'));
    await tester.pumpAndSettle();
    expect(repliesLoaded, 1);
    expect(find.text('已有回复'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '我也说一句');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(sent, ['1:我也说一句']);
  });

  testWidgets('空评论显示占位', (tester) async {
    await tester.pumpWidget(host(CommentThread(
      threadId: 'A_EV_2_1_2',
      loadPage: (limit, offset) async => page([]),
      like: (_, _) async => true,
      loadReplies: (_, __) async => page([]),
      reply: (_, __) async => true,
    )));
    await tester.pumpAndSettle();
    expect(find.text('还没有评论'), findsOneWidget);
  });
}
