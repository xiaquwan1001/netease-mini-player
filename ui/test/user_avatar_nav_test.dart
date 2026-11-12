import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/comment_thread.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_nav.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

rust.FeedEventDto event(int id, int userId) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_$userId',
  userId: BigInt.from(userId),
  kind: 'text',
  userName: '用户$userId',
  text: '一条动态',
  images: const [],
  title: '',
  timeMs: BigInt.from(1700000000000 - id * 1000),
  liked: false,
  likedCount: BigInt.zero,
  shareCount: BigInt.zero,
  commentCount: BigInt.zero,
);

rust.Comment comment(int id, int userId) => rust.Comment(
  id: BigInt.from(id),
  userId: BigInt.from(userId),
  userName: '评论者$userId',
  content: '好听',
  timeMs: BigInt.from(1700000000000),
  likedCount: BigInt.zero,
  liked: false,
  replyCount: BigInt.zero,
  ipLocation: '',
  hot: false,
  parentId: BigInt.zero,
);

void main() {
  tearDown(() => UserNav.opener = null);

  testWidgets('头像点击回调用户 id(uid=0 不拦截)', (tester) async {
    BigInt? opened;
    UserNav.opener = (context, userId, {nickname}) async => opened = userId;

    await tester.pumpWidget(
      host(
        Column(
          children: [
            UserAvatarTap(
              userId: BigInt.from(42),
              nickname: '小明',
              child: const CircleAvatar(child: Text('A')),
            ),
            UserAvatarTap(
              userId: BigInt.zero,
              child: const CircleAvatar(child: Text('B')),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('A'));
    expect(opened, BigInt.from(42));

    opened = null;
    await tester.tap(find.text('B'));
    expect(opened, isNull, reason: '未知 uid 不跳转');
  });

  testWidgets('动态卡片头像进入用户主页', (tester) async {
    BigInt? opened;
    UserNav.opener = (context, userId, {nickname}) async => opened = userId;

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [event(1, 7), event(2, 8)],
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(UserAvatarTap).first);
    expect(opened, BigInt.from(7));
  });

  testWidgets('评论头像进入用户主页', (tester) async {
    BigInt? opened;
    UserNav.opener = (context, userId, {nickname}) async => opened = userId;

    await tester.pumpWidget(
      host(
        CommentThread(
          kind: 'song',
          resourceId: BigInt.one,
          loadPage: (limit, offset) async => rust.CommentPage(
            threadId: 'R_SO_4_1',
            comments: [comment(1, 99)],
            total: BigInt.one,
            hasMore: false,
          ),
          loadHot: (limit, offset) async => rust.CommentPage(
            threadId: 'R_SO_4_1',
            comments: const [],
            total: BigInt.zero,
            hasMore: false,
          ),
          like: (_, _) async => true,
          loadReplies: (parentId, limit) async => rust.CommentPage(
            threadId: 'R_SO_4_1',
            comments: const [],
            total: BigInt.zero,
            hasMore: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(UserAvatarTap).first);
    expect(opened, BigInt.from(99));
  });
}
