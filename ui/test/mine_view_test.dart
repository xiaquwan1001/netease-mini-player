import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/user_page.dart' show UserPage;
import 'package:minincm/src/rust/api.dart' as rust;

rust.SongDto song(int id, String name) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: '艺人',
  artistId: BigInt.one,
  album: '专辑',
  albumId: BigInt.one,
  coverUrl: null,
  durationMs: BigInt.from(1000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

/// 我的资料(简介/等级/uid) —— 「我的」页的简介/动态/我的主页都靠它
rust.ProfileDetail profileDetail({String signature = ''}) => rust.ProfileDetail(
  userId: BigInt.from(42),
  nickname: '我的账号',
  avatarUrl: null,
  backgroundUrl: null,
  signature: signature,
  vip: false,
  follows: BigInt.from(3),
  followeds: BigInt.from(4),
  level: BigInt.from(7),
);

rust.FeedEventDto feedEvent(int id, {String text = '今天听了点什么'}) =>
    rust.FeedEventDto(
      id: BigInt.from(id),
      threadId: 'A_EV_$id',
      userId: BigInt.from(42),
      kind: 'text',
      userName: '我的账号',
      avatarUrl: null,
      text: text,
      song: null,
      coverUrl: null,
      images: const [],
      videoUrl: null,
      title: '',
      timeMs: BigInt.from(DateTime.now().millisecondsSinceEpoch - 60000),
      liked: false,
      likedCount: BigInt.from(2),
      shareCount: BigInt.zero,
      commentCount: BigInt.from(1),
    );

/// 我的页现在顶部有「资料卡 + 我的主页 + 简介 + 我的动态」, 默认 800x600 视口
/// 放不下我喜欢; 需要看到下方区块的用例统一放大视口.
void setTallView(
  WidgetTester tester, {
  double width = 420,
  double height = 1200,
}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
}

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

MineView buildMine({
  required bool loggedIn,
  void Function(List<rust.SongDto>, int)? onPlay,
  VoidCallback? onLogin,

  /// 覆盖收藏歌单/专辑/播客的返回数据(排序用例用)
  List<rust.Playlist>? playlists,
  List<rust.AlbumItem>? albums,
  List<rust.PodcastRadio>? podcasts,

  /// 我的资料(简介内容)
  rust.ProfileDetail? profile,

  /// 我的动态(缺省一条文字动态)
  List<rust.FeedEventDto>? events,

  /// 保存简介(不传 = 后端未接入, 只提示)
  Future<void> Function(String signature)? saveSignature,
}) => MineView(
  loggedIn: loggedIn,
  onLogin: onLogin ?? () {},
  onOpenAccounts: () {},
  loadLiked: () async => [song(1, '喜欢的歌')],
  loadPlaylists: () async =>
      playlists ??
      [
        rust.Playlist(
          id: BigInt.from(2),
          name: '收藏歌单',
          coverUrl: null,
          trackCount: BigInt.from(5),
          special: false,
          subscribed: false,
        ),
      ],
  loadPodcasts: () async =>
      podcasts ??
      [
        rust.PodcastRadio(
          id: BigInt.from(3),
          name: '收藏播客',
          coverUrl: null,
          description: '',
          djName: '主播',
          programCount: BigInt.from(2),
          playCount: BigInt.zero,
        ),
      ],
  onPlaySongs: onPlay ?? (_, _) {},
  onOpenPlaylist: (_) {},
  onOpenPodcast: (_) {},
  onOpenLiked: () {},
  onOpenRecent: () {},
  onOpenFollows: () async {},
  onOpenFolloweds: () async {},
  onOpenAlbum: (_) {},
  loadAlbums: () async =>
      albums ??
      [
        rust.AlbumItem(
          id: BigInt.from(4),
          name: '收藏专辑',
          coverUrl: null,
          artist: '艺人',
          trackCount: BigInt.from(10),
        ),
      ],
  loadProfile: () async => profile ?? profileDetail(),
  loadMyEvents: (uid) async => events ?? [feedEvent(1)],
  saveSignature: saveSignature,
  loadRecent: () async => [song(7, '最近听的歌')],
  loadRanking: (period) async => [
    rust.PlayRankEntryDto(
      song: song(period == 'week' ? 9 : 8, period == 'week' ? '本周常听' : '最常听'),
      playCount: BigInt.from(period == 'week' ? 3 : 42),
      score: BigInt.from(period == 'week' ? 30 : 420),
    ),
  ],
);

void main() {
  testWidgets('未登录时只显示登录引导', (tester) async {
    var logins = 0;
    await tester.pumpWidget(
      host(buildMine(loggedIn: false, onLogin: () => logins++)),
    );
    expect(find.textContaining('登录后查看'), findsOneWidget);
    await tester.tap(find.text('登录'));
    expect(logins, 1);
  });

  testWidgets('登录后展示我喜欢/歌单/播客(关注艺人在独立 tab)', (tester) async {
    setTallView(tester);
    List<rust.SongDto>? played;
    int? index;
    await tester.pumpWidget(
      host(
        buildMine(
          loggedIn: true,
          onPlay: (songs, i) {
            played = songs;
            index = i;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 顶部现在是「资料卡 / 我的主页 / 简介 / 我的动态」(需求 1/2),
    // 我喜欢被推到下面 —— 按真实用户路径滚过去。
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('我喜欢的音乐'),
      200,
      scrollable: scrollable,
    );
    expect(find.text('我喜欢的音乐'), findsOneWidget);
    expect(find.text('喜欢的歌'), findsOneWidget);

    await tester.tap(find.text('喜欢的歌'));
    expect(played?.single.name, '喜欢的歌');
    expect(index, 0);

    // 下半部分要滚动才会被 ListView 构建
    await tester.scrollUntilVisible(
      find.text('收藏的歌单'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('收藏的歌单'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('收藏播客'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('收藏播客'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('收藏的专辑'),
      300,
      scrollable: scrollable,
    );
    expect(find.text('收藏的专辑'), findsOneWidget);
    // 关注艺人不在这里: 已挪到独立的「关注」tab
    expect(find.text('关注艺人'), findsNothing);
  });

  testWidgets('登录后下方有听歌排行, 支持总排行/当周切换', (tester) async {
    await tester.pumpWidget(host(buildMine(loggedIn: true)));
    await tester.pumpAndSettle();

    // 听歌排行在"我的"最下方(收藏专辑/最近听过都在它前面), 要滚到底
    await tester.scrollUntilVisible(
      find.text('当周'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('听歌排行'), findsOneWidget);
    expect(find.text('最常听'), findsOneWidget);

    await tester.tap(find.text('当周'));
    await tester.pumpAndSettle();
    expect(find.text('本周常听'), findsOneWidget);
    expect(find.text('最常听'), findsNothing);
  });

  testWidgets('收藏专辑默认在收藏播客前; 播客最近交互后换到前面', (tester) async {
    await tester.pumpWidget(host(buildMine(loggedIn: true)));
    await tester.pumpAndSettle();

    // 两个区块在页面下半部分, 滚到它们同时可见
    await tester.drag(find.byType(ListView).first, const Offset(0, -1400));
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('收藏的专辑')).dy,
      lessThan(tester.getTopLeft(find.text('收藏的播客')).dy),
      reason: '两边都没有交互记录时按默认顺序: 专辑 → 播客',
    );

    // 专辑记一条更早的、播客记一条更晚的 ⇒ 播客应排到前面
    final settings = AppSettings.instance;
    await settings.touchInteraction('album', BigInt.from(4), nowMs: 1000);
    await settings.touchInteraction('podcast', BigInt.from(3), nowMs: 2000);
    await tester.pumpAndSettle();

    expect(find.text('收藏的播客'), findsOneWidget);
    expect(find.text('收藏的专辑'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('收藏的播客')).dy,
      lessThan(tester.getTopLeft(find.text('收藏的专辑')).dy),
      reason: '播客最近被打开过, 应换到专辑之前',
    );
  });

  testWidgets('收藏歌单按最近交互倒序, 无记录时保持后端顺序', (tester) async {
    await tester.pumpWidget(
      host(
        buildMine(
          loggedIn: true,
          playlists: [
            rust.Playlist(
              id: BigInt.from(20),
              name: '歌单A',
              coverUrl: null,
              trackCount: BigInt.from(1),
              special: false,
              subscribed: false,
            ),
            rust.Playlist(
              id: BigInt.from(21),
              name: '歌单B',
              coverUrl: null,
              trackCount: BigInt.from(2),
              special: false,
              subscribed: false,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('收藏的歌单'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('歌单A')).dx,
      lessThan(tester.getTopLeft(find.text('歌单B')).dx),
      reason: '没有交互记录时保持后端返回顺序',
    );

    await AppSettings.instance.touchInteraction(
      'playlist',
      BigInt.from(21),
      nowMs: 5000,
    );
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('歌单B')).dx,
      lessThan(tester.getTopLeft(find.text('歌单A')).dx),
      reason: '最近打开过的歌单排到最前',
    );
  });

  testWidgets('300dp + 1.25 字号: 未登录引导不溢出', (tester) async {
    await pumpNarrow(tester, Scaffold(body: buildMine(loggedIn: false)));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  // ── 需求 1/2: 「我的」页与「其他用户主页」统一结构 ──────────────────
  //
  // 之前「我的」页看不到自己的简介、没有动态入口、也不能改简介; 现在:
  // 资料卡 / 我的主页 / 简介(空也给文案 + 编辑) / 我的动态(可下拉刷新)。
  testWidgets('简介区块: 空时给明确文案 + 编辑入口', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(buildMine(loggedIn: true, profile: profileDetail())),
    );
    await tester.pumpAndSettle();

    expect(find.text('简介'), findsOneWidget);
    expect(find.text('还没有填写简介'), findsOneWidget);
    expect(find.text('编辑简介'), findsOneWidget);
  });

  testWidgets('简介区块: 有签名时展示签名文本', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(
        buildMine(loggedIn: true, profile: profileDetail(signature: '听歌就好')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('听歌就好'), findsOneWidget);
    expect(find.text('还没有填写简介'), findsNothing);
    expect(find.text('编辑简介'), findsOneWidget);
  });

  // 需求 5: 后端(修改用户资料)接口未接入 ⇒ 弹输入框但不伪造成功
  testWidgets('编辑简介: 点按钮弹输入框, 未接后端时如实提示', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(buildMine(loggedIn: true, profile: profileDetail(signature: '旧签名'))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑简介'));
    await tester.pumpAndSettle();

    // 输入框带出当前简介
    expect(find.byType(TextField), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '旧签名',
    );

    await tester.enterText(find.byType(TextField), '新签名');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing, reason: '保存后弹窗关闭');
    expect(find.textContaining('还没接入后端接口'), findsOneWidget);
  });

  testWidgets('编辑简介: 注入 saveSignature 时真的保存并回填', (tester) async {
    setTallView(tester);
    String? saved;
    await tester.pumpWidget(
      host(
        buildMine(
          loggedIn: true,
          profile: profileDetail(),
          saveSignature: (signature) async => saved = signature,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑简介'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新签名');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(saved, '新签名');
    expect(find.text('简介已保存'), findsOneWidget);
  });

  testWidgets('我的动态: 区块可见并展示最近动态', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(
      host(buildMine(loggedIn: true, events: [feedEvent(1, text: '今天听了点什么')])),
    );
    await tester.pumpAndSettle();

    expect(find.text('我的动态'), findsOneWidget);
    expect(find.text('今天听了点什么'), findsOneWidget);
    expect(find.text('查看全部'), findsWidgets);
  });

  testWidgets('我的动态: 没有动态时给明确空态', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(host(buildMine(loggedIn: true, events: const [])));
    await tester.pumpAndSettle();

    expect(find.text('还没有发布动态'), findsOneWidget);
  });

  // 需求 2: 能跳到自己对外的主页形态(复用 user_page, 不另写资料卡)
  testWidgets('我的主页: 入口可见, 点击进自己的用户主页', (tester) async {
    setTallView(tester);
    await tester.pumpWidget(host(buildMine(loggedIn: true)));
    await tester.pumpAndSettle();

    expect(find.text('我的主页'), findsOneWidget);
    await tester.tap(find.text('我的主页'));
    await tester.pumpAndSettle();

    expect(find.byType(UserPage), findsOneWidget);
  });
}

/// 窄屏 + 大字号回归宿主: 300dp 宽 + 1.25 字号(builder 层注入, 对弹层也生效).
Future<void> pumpNarrow(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(300, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(1.25)),
        child: child!,
      ),
      home: home,
    ),
  );
}
