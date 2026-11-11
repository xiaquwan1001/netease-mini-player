// 评论归属展示: 楼层里的回复必须显示「回复 @某人」, 否则跟独立评论长得一样.
//
// 数据来源: Rust 侧 parse_comment 把 `beReplied[0].user.nickname` 落到 repliedTo,
// `parentCommentId` 落到 parentId(见 ncm-service/src/netease.rs); 这里只验 UI 用它。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.Comment c(
  int id,
  String content, {
  String? repliedTo,
  int parentId = 0,
  int replyCount = 0,
}) =>
    rust.Comment(
      id: BigInt.from(id),
      userId: BigInt.from(100 + id),
      userName: '用户$id',
      avatarUrl: null,
      content: content,
      timeMs: BigInt.from(1700000000000),
      likedCount: BigInt.zero,
      liked: false,
      replyCount: BigInt.from(replyCount),
      ipLocation: '',
      hot: false,
      repliedTo: repliedTo,
      parentId: BigInt.from(parentId),
    );

Future<void> pumpThread(
  WidgetTester tester,
  List<rust.Comment> items, {
  Size size = const Size(900, 1200),
  double textScale = 1.0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CommentThread(
              kind: 'song',
              resourceId: BigInt.from(1),
              loadPage: (limit, offset) async => rust.CommentPage(
                threadId: 'R_SO_4_1',
                comments: items,
                total: BigInt.from(items.length),
                hasMore: false,
              ),
              loadHot: (limit, offset) async => rust.CommentPage(
                threadId: 'R_SO_4_1',
                comments: const [],
                total: BigInt.zero,
                hasMore: false,
              ),
              like: (commentId, liked) async => true,
              loadReplies: (parentId, limit) async => rust.CommentPage(
                threadId: 'R_SO_4_1',
                comments: const [],
                total: BigInt.zero,
                hasMore: false,
              ),
              reply: (commentId, content) async => true,
              delete: (commentId) async => true,
              myUid: BigInt.from(999),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // 首帧
  await tester.pump(); // 第一页返回
}

void main() {
  testWidgets('楼层里的回复显示「回复 @某人」, 顶层评论不显示', (tester) async {
    await pumpThread(tester, [
      c(1, '顶层评论'),
      c(2, '这是回复', repliedTo: '楼主', parentId: 1),
    ]);

    expect(find.textContaining('回复 @楼主'), findsOneWidget);
    // 顶层评论没有归属标记
    expect(find.textContaining('回复 @用户1'), findsNothing);
    // 内容仍然完整显示
    expect(find.text('这是回复'), findsOneWidget);
  });

  testWidgets('空昵称不渲染半个「回复 @」', (tester) async {
    await pumpThread(tester, [c(3, '没有归属信息')]);
    expect(find.textContaining('回复 @'), findsNothing);
  });

  testWidgets('300dp + 1.25 字号下带归属的评论不溢出', (tester) async {
    await pumpThread(
      tester,
      [c(4, '一个很长很长的评论内容' * 3, repliedTo: '名字很长的楼主大人', parentId: 1)],
      size: const Size(300, 800),
      textScale: 1.25,
    );
    expect(tester.takeException(), isNull);
  });
}
