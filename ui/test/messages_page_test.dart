import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/messages_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.MessageCountsDto counts({
  int private = 0,
  int notices = 0,
  int comments = 0,
}) =>
    rust.MessageCountsDto(
      private: private,
      notices: notices,
      comments: comments,
      forwards: 0,
      total: private + notices + comments,
    );

rust.PrivateSessionDto session(int uid, String name, String last, int unread) =>
    rust.PrivateSessionDto(
      userId: BigInt.from(uid),
      nickname: name,
      avatarUrl: null,
      lastMessage: last,
      lastTimeMs: BigInt.from(1700000000000),
      unread: unread,
    );

rust.PrivateMessageDto message(int id, String content, {bool mine = false}) =>
    rust.PrivateMessageDto(
      id: BigInt.from(id),
      fromMe: mine,
      nickname: mine ? '我' : '对方',
      avatarUrl: null,
      content: content,
      timeMs: BigInt.from(1700000000000),
    );

rust.InboxItemDto inbox(
  int id,
  String kind,
  String actor,
  String text, {
  String detail = '',
}) =>
    rust.InboxItemDto(
      id: BigInt.from(id),
      kind: kind,
      actor: actor,
      avatarUrl: null,
      text: text,
      detail: detail,
      timeMs: BigInt.from(1700000000000),
    );

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('消息页: 页签带未读数, 私信列表可点开只读会话', (tester) async {
    await tester.pumpWidget(host(MessagesPage(
      loadCounts: () async => counts(private: 3, notices: 1, comments: 2),
      loadSessions: () async => [session(7, '云音乐VIP', '本月等级权益已更新', 3)],
      loadHistory: (uid) async => [
        message(1, '你好'),
        message(2, '在的', mine: true),
      ],
      loadNotices: () async => [inbox(1, 'notice', '小明', '赞了你的主页背景')],
      loadComments: () async => [
        inbox(2, 'comment', '小红', '来了来了', detail: '我喜欢的音乐'),
      ],
    )));
    await tester.pumpAndSettle();

    expect(find.text('私信 3'), findsOneWidget);
    expect(find.text('通知 1'), findsOneWidget);
    expect(find.text('评论 2'), findsOneWidget);
    expect(find.text('云音乐VIP'), findsOneWidget);
    expect(find.text('本月等级权益已更新'), findsOneWidget);

    await tester.tap(find.text('云音乐VIP'));
    await tester.pumpAndSettle();
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('在的'), findsOneWidget);
    expect(find.text('这里只读: 回复请到官方客户端'), findsOneWidget);
  });

  testWidgets('消息页: 通知/评论页签各渲染一行', (tester) async {
    await tester.pumpWidget(host(MessagesPage(
      loadCounts: () async => counts(),
      loadSessions: () async => const [],
      loadHistory: (uid) async => const [],
      loadNotices: () async => [inbox(1, 'notice', '小明', '赞了你的主页背景')],
      loadComments: () async => [
        inbox(2, 'comment', '小红', '来了来了', detail: '我喜欢的音乐'),
      ],
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('通知'));
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsOneWidget);
    expect(find.textContaining('赞了你的主页背景'), findsOneWidget);

    await tester.tap(find.text('评论'));
    await tester.pumpAndSettle();
    expect(find.text('小红'), findsOneWidget);
    expect(find.textContaining('来了来了'), findsOneWidget);
    expect(find.textContaining('我喜欢的音乐'), findsOneWidget);
  });

  testWidgets('消息页: 加载失败给错误与重试', (tester) async {
    var calls = 0;
    await tester.pumpWidget(host(MessagesPage(
      loadCounts: () async => throw Exception('[auth] 未登录'),
      loadSessions: () async {
        calls++;
        if (calls == 1) throw Exception('[auth] 未登录');
        return [session(7, '云音乐VIP', 'hi', 0)];
      },
      loadHistory: (uid) async => const [],
      loadNotices: () async => const [],
      loadComments: () async => const [],
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('未登录'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('云音乐VIP'), findsOneWidget);
  });
}
