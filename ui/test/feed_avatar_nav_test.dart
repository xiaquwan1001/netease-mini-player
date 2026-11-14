import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_nav.dart';
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_nav.dart';
import 'package:minincm/src/user_page.dart';

/// 头像点击的统一口径回归(2026-11-14, 车道 NAV):
///
/// 网易云的 user id 与 artist id 是两个 id 空间。动态里的作者只带 user id
/// (event.user 没有 artistId, 只有 userType), 真正的映射在 user_detail 的
/// `profile.artistId`。所以 [UserAvatarTap] 必须先解析艺人身份:
///   - 有 artistId -> 艺人主页(与「搜索 -> 艺人」同一个页面);
///   - 没有       -> 用户主页(UserPage)。
///
/// 这里用注入的 resolver + 假的打开动作断言"落到哪个页面", 不联网。

rust.FeedEventDto event({
  required int id,
  required int userId,
  required String userName,
  String text = '正文',
}) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_$userId',
  userId: BigInt.from(userId),
  kind: 'text',
  userName: userName,
  text: text,
  images: const [],
  title: '',
  timeMs: BigInt.from(1700000000000 - id * 1000),
  liked: false,
  likedCount: BigInt.zero,
  shareCount: BigInt.zero,
  commentCount: BigInt.zero,
);

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// 记录"进了哪个页面"的两条通道: 艺人页走 ArtistNav.opener, 用户页走 UserNav.userOpener
class _NavLog {
  final List<(BigInt, String?)> artist = <(BigInt, String?)>[];
  final List<(BigInt, String?)> user = <(BigInt, String?)>[];
}

void main() {
  late _NavLog log;

  setUp(() {
    log = _NavLog();
    ArtistNav.opener = (context, artistId, {name}) async {
      log.artist.add((artistId, name));
    };
    // 只接管"进用户页"这一步: 真 showUserPage 会联网拉资料
    UserNav.userOpener = (context, userId, {nickname}) async {
      log.user.add((userId, nickname));
    };
  });

  tearDown(() {
    ArtistNav.opener = null;
    UserNav.userOpener = null;
    UserNav.opener = null;
    UserNav.artistIdResolver = null;
    UserNav.clearCache();
  });

  testWidgets('动态卡头像: 作者有 artistId -> 进艺人页(与搜索艺人一致)', (tester) async {
    // 音乐人账号 user id=1373758224 的 artistId=1064078(线上实测)
    UserNav.artistIdResolver = (uid) async =>
        uid == BigInt.from(1373758224) ? BigInt.from(1064078) : BigInt.zero;

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(
              id: 1,
              userId: 1373758224,
              userName: 'OfficialXeuphoria',
              text: '音乐人动态',
            ),
          ],
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 卡片(非分类条)里的头像: 第二个 UserAvatarTap(第一个在分类条上)
    final avatars = find.byWidgetPredicate((w) => w is UserAvatarTap);
    await tester.tap(avatars.last);
    await tester.pumpAndSettle();

    expect(log.artist, [(BigInt.from(1064078), 'OfficialXeuphoria')]);
    expect(log.user, isEmpty, reason: '音乐人不该落用户主页');
  });

  testWidgets('动态卡头像: 普通用户(无 artistId) -> 进用户页', (tester) async {
    UserNav.artistIdResolver = (uid) async => BigInt.zero;

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(id: 1, userId: 42, userName: '普通用户', text: '普通动态'),
          ],
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate((w) => w is UserAvatarTap).last);
    await tester.pumpAndSettle();

    expect(log.user, [(BigInt.from(42), '普通用户')]);
    expect(log.artist, isEmpty, reason: '普通用户不该进艺人页');
  });

  testWidgets('解析失败也不挡路: 退回用户页', (tester) async {
    UserNav.artistIdResolver = (uid) async => throw StateError('boom');

    await tester.pumpWidget(
      host(
        FeedView(
          loggedIn: true,
          onLogin: () {},
          onPlaySongs: (_, _) {},
          onOpenUrl: (_) async {},
          loadFeed: () async => [
            event(id: 1, userId: 7, userName: '某人', text: '动态'),
          ],
          loadSubscribedArtists: () async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byWidgetPredicate((w) => w is UserAvatarTap).last);
    await tester.pumpAndSettle();

    expect(log.user, [(BigInt.from(7), '某人')]);
  });

  testWidgets('用户页: 有歌手身份时给出「歌手页」入口', (tester) async {
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1373758224),
          fallbackNickname: 'OfficialXeuphoria',
          loadProfile: (uid) async => rust.ProfileDetail(
            userId: uid,
            artistId: BigInt.from(1064078),
            nickname: 'OfficialXeuphoria',
            signature: '签名',
            vip: false,
            follows: BigInt.one,
            followeds: BigInt.two,
            level: BigInt.from(9),
          ),
          loadPlaylists: (uid) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('歌手页'), findsOneWidget);
    await tester.tap(find.text('歌手页'));
    await tester.pumpAndSettle();
    expect(log.artist, [(BigInt.from(1064078), 'OfficialXeuphoria')]);
  });

  testWidgets('用户页: 普通用户不出现「歌手页」入口', (tester) async {
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(32953014),
          fallbackNickname: 'binaryify',
          loadProfile: (uid) async => rust.ProfileDetail(
            userId: uid,
            nickname: 'binaryify',
            signature: '',
            vip: false,
            follows: BigInt.one,
            followeds: BigInt.one,
            level: BigInt.one,
          ),
          loadPlaylists: (uid) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('歌手页'), findsNothing);
  });
}
