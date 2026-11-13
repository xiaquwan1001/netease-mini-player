import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.Comment comment(
  int id,
  String content, {
  int likedCount = 0,
  bool liked = false,
  int replyCount = 0,
  String ipLocation = '',
  bool hot = false,
}) => rust.Comment(
  id: BigInt.from(id),
  userId: BigInt.from(100 + id),
  userName: '用户$id',
  avatarUrl: null,
  content: content,
  timeMs: BigInt.from(1700000000000),
  likedCount: BigInt.from(likedCount),
  liked: liked,
  replyCount: BigInt.from(replyCount),
  ipLocation: ipLocation,
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
  testWidgets('评论列表: 点赞本地翻转 + 回调, 回复数展示', (tester) async {
    final liked = <String>[];
    await tester.pumpWidget(
      host(
        CommentThread(
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('好听'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    // 「回复」只代表写回复动作; 浏览全量回复由独立的展开入口承担
    expect(find.text('回复'), findsOneWidget);
    expect(find.textContaining('展开全部'), findsOneWidget);

    await tester.tap(find.text('3'));
    await tester.pumpAndSettle();
    expect(liked, ['1:true']);
    expect(find.text('4'), findsOneWidget);
  });

  testWidgets('楼层: 打开回复列表并发回复', (tester) async {
    final sent = <String>[];
    var repliesLoaded = 0;
    await tester.pumpWidget(
      host(
        CommentThread(
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
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('回复'));
    await tester.pumpAndSettle();
    // 预览懒加载已消耗一次, 打开面板再拉一次全量
    expect(repliesLoaded, 2);
    expect(find.text('已有回复'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '我也说一句');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();
    expect(sent, ['1:我也说一句']);
  });

  testWidgets('热门页签: 走热门加载器, 条目显示热门标记与 IP 归属', (tester) async {
    var hotLoaded = 0;
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => page([
            comment(1, '精彩评论', hot: true, likedCount: 100),
            comment(2, '最新评论', ipLocation: '广东'),
          ]),
          loadHot: (limit, offset) async {
            hotLoaded++;
            return page([comment(3, '热门页评论', hot: true)]);
          },
          like: (_, _) async => true,
          loadReplies: (_, _) async => page([]),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 全部页: 精彩评论带"热门"角标(与页签同名, 所以是 2 个), 普通评论显示 IP 归属
    expect(find.text('热门'), findsNWidgets(2));
    expect(find.text('广东'), findsOneWidget);

    await tester.tap(find.byType(ChoiceChip).last);
    await tester.pumpAndSettle();
    expect(hotLoaded, 1);
    expect(find.text('热门页评论'), findsOneWidget);
    expect(find.text('精彩评论'), findsNothing);
  });

  testWidgets('全部页翻页: offset 只数最新评论, 热评不重复追加', (tester) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          pageSize: 10,
          loadPage: (limit, offset) async {
            offsets.add(offset);
            if (offset == 0) {
              return rust.CommentPage(
                threadId: 'R_SO_4_1',
                comments: [
                  comment(1, '热评一', hot: true),
                  comment(2, '热评二', hot: true),
                  comment(3, '最新一'),
                ],
                total: BigInt.from(5),
                hasMore: true,
              );
            }
            return rust.CommentPage(
              threadId: 'R_SO_4_1',
              comments: [comment(2, '热评二', hot: true), comment(4, '最新二')],
              total: BigInt.from(5),
              hasMore: false,
            );
          },
          like: (_, _) async => true,
          loadReplies: (_, _) async => page([]),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('加载更多评论'));
    await tester.pumpAndSettle();
    expect(offsets, [0, 1]);
    expect(find.text('最新二'), findsOneWidget);
    // 热评二只在第一页出现一次
    expect(find.text('热评二'), findsOneWidget);
  });

  testWidgets('空评论显示占位', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          threadId: 'A_EV_2_1_2',
          loadPage: (limit, offset) async => page([]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page([]),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('还没有评论'), findsOneWidget);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: child!,
        ),
        home: Scaffold(
          body: CommentThread(
            kind: 'song',
            resourceId: BigInt.one,
            loadPage: (limit, offset) async =>
                page([comment(1, '一条很长很长很长很长很长很长很长很长的评论', replyCount: 2)]),
            like: (_, _) async => true,
            loadReplies: (parentId, limit) async =>
                page([comment(2, '回复也很长很长很长很长')]),
            reply: (_, _) async => true,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
