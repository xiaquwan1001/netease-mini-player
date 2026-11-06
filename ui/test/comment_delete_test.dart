import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.CommentDto comment(int id, String content, BigInt userId) =>
    rust.CommentDto(
      id: BigInt.from(id),
      userId: userId,
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

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  final me = BigInt.from(42);

  testWidgets('只有自己发的评论显示删除, 确认后回调并移除', (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(host(CommentThread(
      kind: 'song',
      resourceId: BigInt.one,
      myUid: me,
      loadPage: (limit, offset) async => page([
        comment(1, '我的评论', me),
        comment(2, '别人的评论', BigInt.from(7)),
      ]),
      like: (_, _) async => true,
      loadReplies: (_, _) async => page(const []),
      reply: (_, _) async => true,
      delete: (commentId) async {
        deleted.add('$commentId');
        return true;
      },
    )));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsOneWidget, reason: '别人的评论不能删');

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除这条评论?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(deleted, ['1']);
    expect(find.text('我的评论'), findsNothing);
    expect(find.text('别人的评论'), findsOneWidget);
  });

  testWidgets('取消删除不发请求', (tester) async {
    final deleted = <String>[];
    await tester.pumpWidget(host(CommentThread(
      kind: 'song',
      resourceId: BigInt.one,
      myUid: me,
      loadPage: (limit, offset) async => page([comment(1, '我的评论', me)]),
      like: (_, _) async => true,
      loadReplies: (_, _) async => page(const []),
      reply: (_, _) async => true,
      delete: (commentId) async {
        deleted.add('$commentId');
        return true;
      },
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();

    expect(deleted, isEmpty);
    expect(find.text('我的评论'), findsOneWidget);
  });
}
