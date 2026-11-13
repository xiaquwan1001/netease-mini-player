// 他人主页(只读资料 + 公开歌单)的回归.
//
// 背景: 听众列表/关注粉丝列表早就能列出用户, 但"点不动" —— 没有用户主页这个目的地.
// 数据面 = user_profile(user/detail, 匿名可用) + user_playlists_of(user/playlist).
// 这里用注入 loader 覆盖渲染/空态/失败重试, 不联网、不碰 FFI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_page.dart';
import 'package:minincm/src/profile_banner.dart';
import 'package:minincm/src/profile_scaffold.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_page.dart';

rust.ProfileDetail detail({String nickname = '下去玩', String signature = ''}) =>
    rust.ProfileDetail(
      userId: BigInt.from(1822714196),
      nickname: nickname,
      avatarUrl: null,
      backgroundUrl: null,
      signature: signature,
      vip: false,
      follows: BigInt.from(44),
      followeds: BigInt.from(11),
      level: BigInt.from(8),
    );

rust.Playlist playlist(int id, String name, {int count = 2}) => rust.Playlist(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  trackCount: BigInt.from(count),
  special: false,
  subscribed: false,
);

Widget host(Widget child) => MaterialApp(home: child);

/// 用户页现在有 220 高的横幅 + 身份卡 + pinned TabBar, 默认 800x600 视口放不下
/// 歌单卡片; 需要按几何断言/点击卡片的测试统一放大视口.
void setTallView(
  WidgetTester tester, {
  double width = 420,
  double height = 1000,
}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('资料卡 + 公开歌单都渲染', (tester) async {
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1822714196),
          loadProfile: (_) async => detail(signature: '听歌就好'),
          loadPlaylists: (_) async => [
            playlist(1, '想学的指弹曲', count: 2),
            playlist(2, '通勤向/日系R&B', count: 89),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下去玩'), findsWidgets); // AppBar + 资料卡
    expect(find.text('听歌就好'), findsOneWidget);
    expect(find.textContaining('关注 44'), findsOneWidget);
    expect(find.text('想学的指弹曲'), findsOneWidget);
    expect(find.textContaining('89 首'), findsOneWidget);
  });

  testWidgets('没有公开歌单时给明确空态', (tester) async {
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async => detail(nickname: '小红'),
          loadPlaylists: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('没有公开歌单'), findsOneWidget);
  });

  testWidgets('加载失败: 给出错误与重试, 重试成功后正常显示', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async {
            attempts++;
            // 用非 network 错误: retryNetwork 只重试网络错, 这里要的是首屏失败这个状态
            if (attempts == 1) throw Exception('[internal] boom');
            return detail(nickname: '小红');
          },
          loadPlaylists: (_) async => [playlist(1, '一个歌单')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('加载失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('一个歌单'), findsOneWidget);
    expect(find.text('加载失败'), findsNothing);
  });

  testWidgets('300dp + 1.25 字号不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.25)),
          child: UserPage(
            userId: BigInt.from(1822714196),
            loadProfile: (_) async => detail(signature: '一段很长很长的签名用于小屏回归测试'),
            loadPlaylists: (_) async => [
              playlist(1, '一个名字特别特别长的歌单用于小屏回归测试', count: 89),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('下去玩'), findsWidgets);
  });

  testWidgets('歌单标题允许 2 行: 长名字换行而不是单行省略', (tester) async {
    setTallView(tester);
    const longName = '一个名字特别特别特别特别长的歌单';
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async => detail(nickname: '小红'),
          loadPlaylists: (_) async => [playlist(1, longName, count: 2)],
        ),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.text(longName);
    expect(title, findsOneWidget);
    // 卡片标题走 AdaptiveText(mode: wrap, maxLines: 2)
    expect(tester.widget<Text>(title).maxLines, 2);
    final titleHeight = tester.getRect(title).height;
    final fontSize = tester.widget<Text>(title).style?.fontSize ?? 14;
    // 真的换成了两行(单行行高约 1.4 x 字号, 两行 > 1.6 x 字号)
    expect(
      titleHeight,
      greaterThan(fontSize * 1.6),
      reason: '标题应占两行($titleHeight), 单行被截断时只有约 $fontSize',
    );
  });

  testWidgets('关注/粉丝 chip 可点并回调(宿主可覆盖导航)', (tester) async {
    setTallView(tester);
    var followsTaps = 0;
    var fanTaps = 0;
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async => detail(nickname: '小红'),
          loadPlaylists: (_) async => const [],
          onOpenFollows: () => followsTaps++,
          onOpenFolloweds: () => fanTaps++,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // chip 的点击区是 InkWell(可点), 不是纯文本
    expect(
      find.ancestor(of: find.text('关注 44'), matching: find.byType(InkWell)),
      findsWidgets,
    );
    await tester.tap(find.text('关注 44'));
    await tester.pumpAndSettle();
    expect(followsTaps, 1);

    await tester.tap(find.text('粉丝 11'));
    await tester.pumpAndSettle();
    expect(fanTaps, 1);
  });

  testWidgets('关注 chip 切到关注 tab 并渲染列表(无宿主钩子时)', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async => detail(nickname: '小红'),
          loadPlaylists: (_) async => const [],
          loadFollows: (uid, limit, offset) async => [
            rust.UserItem(
              id: BigInt.from(9),
              name: '小明',
              avatarUrl: null,
              signature: '',
              followed: true,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsNothing); // 初始在歌单 tab

    await tester.tap(find.text('关注 44'));
    await tester.pumpAndSettle();
    expect(find.text('小明'), findsOneWidget);
  });

  testWidgets('空分区不渲染: 无歌单/无关注粉丝时只剩歌单 tab, 不塞空态卡', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async => rust.ProfileDetail(
            userId: BigInt.from(1),
            nickname: '小红',
            avatarUrl: null,
            backgroundUrl: null,
            signature: '',
            vip: false,
            follows: BigInt.zero,
            followeds: BigInt.zero,
            level: BigInt.from(3),
          ),
          loadPlaylists: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 空歌单分区: 不渲染「TA 的歌单」标题(也没有空态卡片)
    expect(find.text('TA 的歌单'), findsNothing);
    expect(find.byType(Card), findsNothing);
    // 计数为 0 时不生成关注/粉丝 tab
    expect(find.byType(Tab), findsOneWidget);
    // 但歌单 tab 自身仍给出明确空态
    expect(find.text('没有公开歌单'), findsOneWidget);
  });

  testWidgets('300dp + 1.625 字号: 骨架与统计 chip 不溢出', (tester) async {
    tester.view.physicalSize = const Size(300, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.625)),
          child: child!,
        ),
        home: UserPage(
          userId: BigInt.from(1822714196),
          loadProfile: (_) async => detail(signature: '一段很长很长的签名用于小屏回归测试'),
          loadPlaylists: (_) async => [
            playlist(1, '一个名字特别特别长的歌单用于小屏回归测试', count: 89),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('下去玩'), findsWidgets);
    expect(find.text('关注 44'), findsOneWidget);
  });

  // 「从不同入口进入的个人主页应该调起同一份信息与排版」: 两页共用 ProfileScaffold,
  // 且**缺数据整块不出现**(不生成空 tab、不留占位文案)。
  // 这里用同一份"最小数据形状"分别渲两页, 断言骨架同构 + 缺项 findsNothing。
  testWidgets('同一份数据形状: 两页骨架同构, 缺失条目不渲染', (tester) async {
    setTallView(tester);

    rust.ArtistDetailDto bareArtist() => rust.ArtistDetailDto(
      id: BigInt.from(6452),
      name: '某艺人',
      avatarUrl: null,
      coverUrl: null,
      alias: const [],
      briefDesc: '',
      albumCount: BigInt.zero,
      musicCount: BigInt.zero,
      songs: const [],
      albums: const [],
    );

    await tester.pumpWidget(
      host(
        ArtistDetailPage(
          artistId: BigInt.from(6452),
          name: '某艺人',
          onPlaySongs: (_, _) {},
          loadArtist: (_) async => bareArtist(),
          loadSimilar: (_) async => const [],
          loadSongsPage: (_, _) async =>
              const rust.ArtistSongPageDto(songs: [], hasMore: false),
          loadMvsPage: (_, _) async =>
              const rust.ArtistMvPageDto(mvs: [], hasMore: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final artistIdentity = tester.getRect(find.byType(ProfileIdentity));
    expect(find.byType(ProfileScaffold), findsOneWidget);
    expect(find.byType(ProfileBannerImage), findsOneWidget);
    // 艺人: 无简介/无作品/无专辑/无 MV → 对应区块与 tab 一个都不出现
    expect(find.text('简介'), findsNothing);
    expect(find.text('推荐单曲'), findsNothing);
    expect(find.text('相似艺人'), findsNothing);
    expect(find.textContaining('个专辑'), findsNothing, reason: '作品数为 0 不留统计行');
    expect(find.text('专辑'), findsNothing);
    expect(find.text('MV'), findsNothing);

    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async => rust.ProfileDetail(
            userId: BigInt.from(1),
            nickname: '小红',
            avatarUrl: null,
            backgroundUrl: null,
            signature: '',
            vip: false,
            follows: BigInt.zero,
            followeds: BigInt.zero,
            level: BigInt.zero,
          ),
          loadPlaylists: (_) async => const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ProfileScaffold), findsOneWidget);
    expect(find.byType(ProfileBannerImage), findsOneWidget);
    // 用户: 同一份骨架, 缺的条目同样不渲染(无简介区块、不生成关注/粉丝 tab)
    expect(find.text('简介'), findsNothing);
    expect(find.text('TA 的歌单'), findsNothing);
    expect(find.text('关注'), findsNothing);
    expect(find.text('粉丝'), findsNothing);
    expect(find.byType(Tab), findsOneWidget);

    // 骨架几何一致: 身份卡左右边缘与上沿都在同一条线上
    final userIdentity = tester.getRect(find.byType(ProfileIdentity));
    expect(userIdentity.left, artistIdentity.left);
    expect(userIdentity.width, artistIdentity.width);
    expect(userIdentity.top, artistIdentity.top);
  });

  testWidgets('没有播放回调时点歌单只提示, 不崩', (tester) async {
    await tester.pumpWidget(
      host(
        UserPage(
          userId: BigInt.from(1),
          loadProfile: (_) async => detail(nickname: '小红'),
          loadPlaylists: (_) async => [playlist(1, '一个歌单')],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('一个歌单'));
    await tester.pump();
    expect(find.text('当前页面不支持播放'), findsOneWidget);
  });
}
