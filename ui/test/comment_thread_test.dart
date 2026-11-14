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
  String? userName,
  String? repliedTo,
}) => rust.Comment(
  id: BigInt.from(id),
  userId: BigInt.from(100 + id),
  userName: userName ?? '用户$id',
  repliedTo: repliedTo,
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

  // A1/A2 回归: 头行(昵称/回复@/热门/时间/IP)与动作行(赞/回复/删除)原先都没有
  // flex, 300dp x1.625 下必溢出 —— 时间/IP 现在参与宽度分配(Flexible),
  // 动作行改 Wrap 换行。
  testWidgets('300dp x1.625: 头行五段 + 含删除的动作行都不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 900);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.625;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          // myUid 与评论作者一致 => 动作行多出「删除」, 这是动作最多的形态
          myUid: BigInt.from(101),
          loadPage: (limit, offset) async => page([
            comment(
              1,
              '一条很长很长很长很长很长很长很长很长的评论正文',
              likedCount: 12345,
              hot: true,
              ipLocation: '广东',
              userName: '一个名字特别特别长的用户昵称用于窄屏回归测试',
              repliedTo: '被回复的人名字也很长很长很长',
            ),
          ]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page([]),
          reply: (_, _) async => true,
          delete: (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull, reason: '头行/动作行不允许 overflow');
    // 动作行最多 4 个动作(赞/回复/删除 + 计数): 换行后每个动作仍必须在屏内
    for (final label in ['回复', '删除']) {
      final box = tester.renderObject<RenderBox>(find.text(label).first);
      final right = box.localToGlobal(Offset(box.size.width, 0)).dx;
      expect(right, lessThanOrEqualTo(300.5), reason: '「$label」被挤出屏幕');
    }
    // IP 归属必须单行(先换行再省略会让行高翻倍)
    final ip = tester.renderObject<RenderBox>(find.text('广东'));
    expect(ip.size.height, lessThan(40), reason: 'IP 归属不许竖排');
    expect(ip.size.width, greaterThan(0), reason: 'IP 归属被压到 0 宽');
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
  // 需求 13: 点赞从动作行上移到「用户名 + 发布时间」行(时间右侧), 并展示数量
  // (0 也显示); 与「回复」按钮同一套颜色/描边 token。
  testWidgets('点赞在用户名/时间行且显示数量(0 也显示)', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => page([comment(1, '好听')]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page([]),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 0 赞也显示数字
    expect(find.text('0'), findsOneWidget);
    // 点赞图标与昵称同一行(纵向中心一致, 容差一行内)
    final heart = tester.getCenter(find.byIcon(Icons.favorite_border));
    final name = tester.getCenter(find.text('用户1'));
    expect((heart.dy - name.dy).abs(), lessThan(12));

    // 点赞仍可用: 乐观翻转 + 数字变化
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    // 点赞数字 +1(可能同时存在其它"1"文案, 只要求点赞数字在)
    expect(find.text('1'), findsWidgets);
  });

  // 需求 9: 长按评论(分享面板入口)时评论本身要有与「回复」/高亮同款的
  // 选中底色, 松手褪去 —— 以前长按只有面板弹出, 评论无任何反馈。
  testWidgets('长按评论出现选中底色, 松手褪去', (tester) async {
    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => page([comment(1, '好听')]),
          like: (_, _) async => true,
          loadReplies: (_, _) async => page([]),
          reply: (_, _) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    BoxDecoration tileDecoration() =>
        tester
                .widget<AnimatedContainer>(
                  find
                      .ancestor(
                        of: find.text('好听'),
                        matching: find.byType(AnimatedContainer),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('好听')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(
      tileDecoration().color,
      isNot(Colors.transparent),
      reason: '长按期间整条评论要点亮(选中态)',
    );
    await gesture.up();
    // 选中态由 1.5s 自动褪色定时器收尾(分享面板弹出时框架会取消长按手势)
    await tester.pump(const Duration(milliseconds: 1600));
    expect(tileDecoration().color, Colors.transparent, reason: '松手后选中态褪去');
  });
}
