import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/messages_page.dart';
import 'package:minincm/src/rust/api.dart' as rust;

rust.MessageCountsDto counts({
  int private = 0,
  int notices = 0,
  int comments = 0,
  int forwards = 0,
}) => rust.MessageCountsDto(
  private: private,
  notices: notices,
  comments: comments,
  forwards: forwards,
  total: private + notices + comments + forwards,
);

rust.PrivateSession session(int uid, String name, String last, int unread) =>
    rust.PrivateSession(
      userId: BigInt.from(uid),
      nickname: name,
      avatarUrl: null,
      lastMessage: last,
      lastTimeMs: BigInt.from(1700000000000),
      unread: unread,
    );

rust.PrivateMessage message(
  int id,
  String content, {
  bool mine = false,
  int timeMs = 1700000000000,
}) => rust.PrivateMessage(
  id: BigInt.from(id),
  fromMe: mine,
  nickname: mine ? '我' : '对方',
  avatarUrl: null,
  content: content,
  timeMs: BigInt.from(timeMs),
);

rust.InboxItem inbox(
  int id,
  String kind,
  String actor,
  String text, {
  String detail = '',
}) => rust.InboxItem(
  id: BigInt.from(id),
  kind: kind,
  actor: actor,
  avatarUrl: null,
  text: text,
  detail: detail,
  timeMs: BigInt.from(1700000000000),
);

rust.ForwardItem forward(
  int id,
  String nickname,
  String comment, {
  BigInt? timeMs,
}) => rust.ForwardItem(
  id: BigInt.from(id),
  eventId: BigInt.from(42),
  userId: BigInt.from(7),
  nickname: nickname,
  avatarUrl: null,
  comment: comment,
  timeMs: timeMs ?? BigInt.from(1700000000000),
  forwardType: 1,
  picUrl: null,
);

rust.RecentContact contact(int uid, String nickname, {String? remark}) =>
    rust.RecentContact(
      userId: BigInt.from(uid),
      nickname: nickname,
      avatarUrl: null,
      mutual: true,
      onlined: false,
      vipType: 11,
      remarkName: remark,
    );

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('消息页: 页签带未读数, 私信列表可点开只读会话', (tester) async {
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => counts(private: 3, notices: 1, comments: 2),
          loadSessions: (limit, offset) async => [
            session(7, '云音乐VIP', '本月等级权益已更新', 3),
          ],
          loadHistory: (uid, limit, before) async => [
            message(1, '你好'),
            message(2, '在的', mine: true),
          ],
          loadNotices: () async => [inbox(1, 'notice', '小明', '赞了你的主页背景')],
          loadComments: () async => [
            inbox(2, 'comment', '小红', '来了来了', detail: '我喜欢的音乐'),
          ],
        ),
      ),
    );
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
    // 2026-11: 私信改为可回复, 底部换成输入框(不再有"只读"提示)
    expect(find.text('这里只读: 回复请到官方客户端'), findsNothing);
    expect(find.text('发私信…'), findsOneWidget);
    expect(find.byTooltip('发送'), findsOneWidget);
  });

  testWidgets('消息页: 私信可发送(注入 sender 后调用并重拉历史)', (tester) async {
    final sent = <String>[];
    var reloads = 0;
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => counts(),
          loadSessions: (limit, offset) async => [
            session(7, '云音乐VIP', 'hi', 0),
          ],
          loadHistory: (uid, limit, before) async {
            reloads++;
            return [message(1, '你好')];
          },
          loadNotices: () async => const [],
          loadComments: () async => const [],
          sendPrivate: (uid, content) async {
            sent.add(content);
            return true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('云音乐VIP'));
    await tester.pumpAndSettle();

    final before = reloads;
    await tester.enterText(find.byType(TextField), '收到, 谢谢');
    await tester.tap(find.byTooltip('发送'));
    await tester.pumpAndSettle();

    expect(sent, ['收到, 谢谢']);
    expect(reloads, greaterThan(before), reason: '发送成功后应重拉最新一页');
  });

  testWidgets('消息页: 通知/评论页签各渲染一行', (tester) async {
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => counts(),
          loadSessions: (limit, offset) async => const [],
          loadHistory: (uid, limit, before) async => const [],
          loadNotices: () async => [inbox(1, 'notice', '小明', '赞了你的主页背景')],
          loadComments: () async => [
            inbox(2, 'comment', '小红', '来了来了', detail: '我喜欢的音乐'),
          ],
        ),
      ),
    );
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
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => throw Exception('[auth] 未登录'),
          loadSessions: (limit, offset) async {
            calls++;
            if (calls == 1) throw Exception('[auth] 未登录');
            return [session(7, '云音乐VIP', 'hi', 0)];
          },
          loadHistory: (uid, limit, before) async => const [],
          loadNotices: () async => const [],
          loadComments: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('未登录'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('云音乐VIP'), findsOneWidget);
  });

  testWidgets('消息页: @我页签渲染转发条目与未读数', (tester) async {
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => counts(forwards: 2),
          loadSessions: (limit, offset) async => const [],
          loadHistory: (uid, limit, before) async => const [],
          loadNotices: () async => const [],
          loadComments: () async => const [],
          loadForwards: () async => [
            forward(9001, '小明', '转发了一句话'),
            forward(9002, '', '', timeMs: BigInt.zero),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('@我 2'), findsOneWidget);
    await tester.tap(find.text('@我 2'));
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsOneWidget);
    expect(find.text('转发了一句话'), findsOneWidget);
    expect(find.text('云音乐用户'), findsOneWidget, reason: '昵称缺失给兜底称呼');
  });

  testWidgets('消息页: 私信顶部最近联系人横滑条(备注名优先)', (tester) async {
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => counts(),
          loadSessions: (limit, offset) async => [
            session(7, '云音乐VIP', 'hi', 0),
          ],
          loadHistory: (uid, limit, before) async => const [],
          loadContacts: () async => [
            contact(1, '好友本名', remark: '老王'),
            contact(2, '云音乐VIP'),
          ],
          loadNotices: () async => const [],
          loadComments: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('老王'), findsOneWidget, reason: '有备注名时显示备注');
    expect(find.text('好友本名'), findsNothing);
    expect(find.text('云音乐VIP'), findsNWidgets(2), reason: '联系人与会话各一处');

    // 点联系人名字(非头像) → 直接开聊天面板(头像才进个人主页)
    await tester.tap(find.text('老王'));
    await tester.pumpAndSettle();
    expect(find.text('发私信…'), findsOneWidget, reason: '联系人条点名字应打开聊天面板');
  });

  testWidgets('消息页: 会话列表加载更多(按 user id 去重, 返回 < limit 到底)', (tester) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => counts(),
          pageSize: 2,
          loadSessions: (limit, offset) async {
            offsets.add(offset);
            if (offset == 0) {
              return [session(1, '用户1', 'hi', 0), session(2, '用户2', 'yo', 0)];
            }
            // 第二页带一个与第一页重复的 user id, 必须去重
            if (offset == 2) {
              return [session(2, '用户2', 'yo', 0), session(3, '用户3', 'hey', 0)];
            }
            // 第三页只有 1 条(< limit), 视为到底
            return [session(4, '用户4', 'end', 0)];
          },
          loadHistory: (uid, limit, before) async => const [],
          loadNotices: () async => const [],
          loadComments: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('用户1'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget, reason: '返回条数 == limit 时还有下一页');

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    expect(offsets, [0, 2], reason: '第二页用已消费的行数当 offset');
    expect(find.text('用户3'), findsOneWidget);
    expect(find.text('用户2'), findsOneWidget, reason: '重复会话只保留一条');
    expect(find.text('加载更多'), findsOneWidget, reason: '第二页条数 == limit, 还可能有一页');

    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();

    expect(offsets, [0, 2, 4]);
    expect(find.text('用户4'), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    expect(find.text('没有更多了'), findsOneWidget, reason: '返回条数 < limit 视为到底');
  });

  testWidgets('消息页: 聊天记录加载更早(最早一条 time_ms 当 before_ms)', (tester) async {
    final befores = <BigInt>[];
    await tester.pumpWidget(
      host(
        MessagesPage(
          loadCounts: () async => counts(),
          pageSize: 2,
          loadSessions: (limit, offset) async => [
            session(7, '云音乐VIP', '本月等级权益已更新', 0),
          ],
          loadHistory: (uid, limit, before) async {
            befores.add(before);
            if (before == BigInt.zero) {
              return [
                message(1, '你好', timeMs: 1000),
                message(2, '在的', mine: true, timeMs: 2000),
              ];
            }
            return [message(0, '更早一条', timeMs: 500)];
          },
          loadNotices: () async => const [],
          loadComments: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('云音乐VIP'));
    await tester.pumpAndSettle();
    expect(find.text('加载更早'), findsOneWidget, reason: '返回条数 == limit 时可再往前翻');

    await tester.tap(find.text('加载更早'));
    await tester.pumpAndSettle();

    expect(befores, [
      BigInt.zero,
      BigInt.from(1000),
    ], reason: '用最早一条的 time_ms 当游标, 不重复拉最新页');
    expect(find.text('更早一条'), findsOneWidget);
    expect(find.text('你好'), findsOneWidget);
    expect(find.text('加载更早'), findsNothing);
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
          body: MessagesPage(
            loadCounts: () async => counts(private: 3, notices: 1, comments: 2),
            loadSessions: (limit, offset) async => [
              session(7, '云音乐VIP名字特别长那种', '本月等级权益已更新还有好长一段话', 3),
            ],
            loadHistory: (uid, limit, before) async => [message(1, '你好')],
            loadNotices: () async => [inbox(1, 'notice', '小明', '赞了你的主页背景')],
            loadComments: () async => [inbox(2, 'comment', '小红', '来了来了')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
