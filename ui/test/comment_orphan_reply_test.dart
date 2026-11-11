// 动态评论接口会把一部分回复当顶层返回(parentCommentId + beReplied)。
// 这些必须在 UI 里归位到主评论区, 否则就是用户说的"裸的单独成条"(真机反馈)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.Comment c(
  int id,
  String content, {
  String? name,
  int parentId = 0,
  String? repliedTo,
  int replyCount = 0,
}) =>
    rust.Comment(
      id: BigInt.from(id),
      userId: BigInt.from(100 + id),
      userName: name ?? '用户$id',
      avatarUrl: null,
      content: content,
      timeMs: BigInt.from(1700000000000 + id),
      likedCount: BigInt.zero,
      liked: false,
      replyCount: BigInt.from(replyCount),
      ipLocation: '',
      hot: false,
      repliedTo: repliedTo,
      parentId: BigInt.from(parentId),
    );

rust.CommentPage pageOf(List<rust.Comment> items) => rust.CommentPage(
      threadId: 'A_EV_2_1_2',
      comments: items,
      total: BigInt.from(items.length),
      hasMore: false,
    );

Future<void> pump(WidgetTester tester, List<rust.Comment> page) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: CommentThread(
          threadId: 'A_EV_2_1_2',
          loadPage: (limit, offset) async => pageOf(page),
          // 楼层接口不返回东西: 只验"归位"这一步, 不依赖网络预览
          loadReplies: (parentId, limit) async => pageOf(const []),
          like: (commentId, liked) async => true,
          reply: (commentId, content) async => true,
          myUid: BigInt.from(999),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('被当顶层返回的回复收进主评论, 不再单独成条', (tester) async {
    await pump(tester, [
      c(1, '主评论', name: '楼主', replyCount: 1),
      // 接口把这条回复放进了顶层列表
      c(2, '这是回复', name: '回复者', parentId: 1, repliedTo: '楼主'),
    ]);

    // 顶层只剩主评论
    expect(find.text('主评论'), findsOneWidget);
    // 回复被收进预览(以「昵称：内容」形式出现)
    expect(find.text('回复者：这是回复'), findsOneWidget);
    // 不再有单独的 tile: 昵称行不该出现「回复者」这个作者名 + 回复 @楼主 那行
    expect(find.text('回复 @楼主'), findsNothing);
    expect(find.text('展开全部 1 条回复'), findsOneWidget);
  });

  testWidgets('主评论不在本页时留在顶层并保留「回复 @某人」', (tester) async {
    await pump(tester, [
      c(2, '孤儿回复', name: '回复者', parentId: 99, repliedTo: '楼主'),
    ]);
    expect(find.text('回复 @楼主'), findsOneWidget);
    expect(find.text('孤儿回复'), findsOneWidget);
  });

  testWidgets('replyCount 为 0 但被收进回复时也给展开入口', (tester) async {
    await pump(tester, [
      c(1, '主评论', name: '楼主'),
      c(2, '这是回复', name: '回复者', parentId: 1, repliedTo: '楼主'),
    ]);
    expect(find.text('展开全部 1 条回复'), findsOneWidget);
  });
}
