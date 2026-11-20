// 评论区四态收口(AsyncView)回归:
// 首屏失败一行错误 + 重试只取一次 / 切「全部·热门」重挂载重取 / 楼层回复面板
// 发送失败不再静默(改造前写进只给「整块加载失败」用的那个位置, 列表已加载时看不到)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;

rust.Comment comment(
  int id,
  String content, {
  int replyCount = 0,
  bool hot = false,
}) => rust.Comment(
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
  hot: hot,
  parentId: BigInt.zero,
);

rust.CommentPage page(List<rust.Comment> items) => rust.CommentPage(
  threadId: 'R_SO_4_1',
  comments: items,
  total: BigInt.from(items.length),
  hasMore: false,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('首屏加载失败: 一行错误 + 重试只重取一次', (tester) async {
    var loads = 0;
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async {
            loads++;
            // 非网络错: 不触发 retryNetwork 的退避重试, 测试里不会留 pending timer
            if (loads == 1) throw Exception('[internal] boom');
            return page([comment(1, '好听')]);
          },
          loadHot: (limit, offset) async => page(const []),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page(const []),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(loads, 1);
    expect(
      find.textContaining('boom'),
      findsOneWidget,
      reason: '文案走 friendlyError',
    );
    expect(find.text('重试'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(loads, 2, reason: '一次重试只触发一次取数');
    expect(find.text('好听'), findsOneWidget);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('切「热门」页签: 重挂载重取, 加载态回来', (tester) async {
    var hotLoads = 0;
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => page([comment(1, '最新评论')]),
          loadHot: (limit, offset) async {
            hotLoads++;
            return page([comment(2, '精彩评论', hot: true)]);
          },
          like: (_, _) async => true,
          loadReplies: (_, _) async => page(const []),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('最新评论'), findsOneWidget);
    expect(hotLoads, 0);

    await tester.tap(find.text('热门'));
    await tester.pumpAndSettle();
    expect(hotLoads, 1);
    expect(find.text('精彩评论'), findsOneWidget);
    expect(find.text('最新评论'), findsNothing);

    // 切回「全部」: 再走默认加载器
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.text('最新评论'), findsOneWidget);
    expect(hotLoads, 1);
  });

  testWidgets('楼层回复面板: 发送失败给提示(不再静默)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async =>
              page([comment(1, '父评论', replyCount: 1)]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page(const []),
          reply: (_, _) async => throw Exception('[internal] boom'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('回复'));
    await tester.pumpAndSettle();
    expect(find.text('还没有回复'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '发不出去的回复');
    await tester.tap(find.text('发送'));
    await tester.pumpAndSettle();

    expect(find.textContaining('boom'), findsOneWidget, reason: '失败要看得见');
    // 面板不关(用户还能改完再发)
    expect(find.text('还没有回复'), findsOneWidget);
  });
}
