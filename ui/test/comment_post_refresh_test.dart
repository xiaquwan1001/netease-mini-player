// 发表评论后的回填与定位: 乐观项「我 / 刚刚 / 无头像」必须被服务端真实数据替换,
// 否则用户要退出重进才看得到正常的昵称/头像(实测 bug)。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/rust/api.dart' as rust;

const _myUid = 42;

rust.Comment serverComment(
  int id,
  String content, {
  String name = '下去玩',
  String? avatar = 'https://p1.music.126.net/a.jpg',
  int uid = _myUid,
}) =>
    rust.Comment(
      id: BigInt.from(id),
      userId: BigInt.from(uid),
      userName: name,
      avatarUrl: avatar,
      content: content,
      timeMs: BigInt.from(1700000000000),
      likedCount: BigInt.zero,
      liked: false,
      replyCount: BigInt.zero,
      ipLocation: '安徽',
      hot: false,
      parentId: BigInt.zero,
    );

rust.CommentPage pageOf(List<rust.Comment> items) => rust.CommentPage(
      threadId: 'R_SO_4_1',
      comments: items,
      total: BigInt.from(items.length),
      hasMore: false,
    );

void main() {
  testWidgets('发表成功: 乐观项被服务端真实昵称/头像替换, 且不重复', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var sends = 0;
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CommentThread(
            kind: 'song',
            resourceId: BigInt.one,
            loadPage: (limit, offset) async {
              loads++;
              // 第一次什么都没有; 发表后的静默重取才有那条评论
              return pageOf(sends == 0 ? const [] : [serverComment(7, '早')]);
            },
            loadHot: (limit, offset) async => pageOf(const []),
            like: (commentId, liked) async => true,
            loadReplies: (parentId, limit) async => pageOf(const []),
            reply: (commentId, content) async {
              sends++;
              return true;
            },
            myUid: BigInt.from(_myUid),
          ),
        ),
      ),
    ));
    await tester.pump(); // 首帧
    await tester.pump(); // 第一页(空)

    expect(find.text('还没有评论'), findsOneWidget);

    // 打开写评论面板 → 输入 → 发送
    await tester.tap(find.text('写评论…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350)); // 面板滑入
    await tester.enterText(find.byType(TextField).last, '早');
    await tester.pump(); // 输入后让「发送」按钮重建为可点
    expect(find.text('发送'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    await tester.tap(find.text('发送'));
    await tester.pump(); // 乐观插入 + 发起请求
    expect(sends, 1, reason: '发送按钮必须真的触发 reply hook');
    await tester.pump(); // 发送返回
    await tester.pump(); // 静默重取返回
    await tester.pump(const Duration(milliseconds: 400)); // 面板关闭/高亮动画

    // 回填后: 真实昵称出现, 假的「我」不再有, 也没有重复两条
    expect(find.text('下去玩'), findsOneWidget);
    expect(find.text('我'), findsNothing);
    expect(find.text('早'), findsOneWidget);
    expect(sends, 1);
    expect(loads, greaterThanOrEqualTo(2));
  });

  testWidgets('静默重取失败: 保留乐观项, 不把整页打成错误', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    var sends = 0;
    var loads = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: CommentThread(
            kind: 'song',
            resourceId: BigInt.one,
            loadPage: (limit, offset) async {
              loads++;
              if (loads == 1) return pageOf(const []);
              // 非网络错: 不触发 retryNetwork 的退避重试, 测试里不会留 pending timer
              throw Exception('[internal] boom');
            },
            loadHot: (limit, offset) async => pageOf(const []),
            like: (commentId, liked) async => true,
            loadReplies: (parentId, limit) async => pageOf(const []),
            reply: (commentId, content) async {
              sends++;
              return true;
            },
            myUid: BigInt.from(_myUid),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('写评论…'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).last, '早');
    await tester.pump(); // 输入后让「发送」按钮重建为可点
    expect(find.text('发送'), findsOneWidget);
    await tester.tap(find.text('发送'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(sends, 1);
    expect(find.text('还没有评论'), findsNothing, reason: '调试: 是否被清空');
    // 乐观项还在(用户看到的还是自己的评论), 没有错误页/重试按钮
    expect(find.text('我'), findsOneWidget);
    expect(find.text('重试'), findsNothing);
    // 让高亮计时器/动画走完, 不留 pending timer
    await tester.pump(const Duration(seconds: 2));
  });
}
