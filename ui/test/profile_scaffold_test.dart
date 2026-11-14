// 艺人页 / 他人主页共用骨架(ProfileScaffold)的几何一致性回归.
//
// 统一前两页结构完全不一样(艺人: NestedScrollView + SliverAppBar; 用户: AppBar +
// ListView 卡片), 于是横幅高度/身份卡位置/pinned TabBar 位置各不相同。
// 这里用 bounding box 把"同一套骨架"钉死: 横幅高度、身份卡是否贴在横幅下沿、
// 收起后 TabBar 是否都钉在顶栏下方同一条线。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_page.dart';
import 'package:minincm/src/profile_banner.dart';
import 'package:minincm/src/profile_scaffold.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/user_page.dart';

rust.ArtistDetailDto artistDetail() => rust.ArtistDetailDto(
  id: BigInt.from(6452),
  name: '周杰伦',
  avatarUrl: null,
  coverUrl: null,
  alias: const ['Jay Chou'],
  briefDesc: '一句话简介',
  albumCount: BigInt.zero,
  musicCount: BigInt.from(2),
  songs: [
    rust.SongDto(
      id: BigInt.from(1),
      name: '晴天',
      artist: '周杰伦',
      artistId: BigInt.from(6452),
      album: '叶惠美',
      albumId: BigInt.from(2),
      durationMs: BigInt.from(200000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    ),
  ],
  albums: const [],
);

rust.ProfileDetail userDetail() => rust.ProfileDetail(
  userId: BigInt.from(1),
  nickname: '下去玩',
  avatarUrl: null,
  backgroundUrl: null,
  signature: '听歌就好',
  vip: false,
  follows: BigInt.zero,
  followeds: BigInt.zero,
  level: BigInt.from(8),
);

Widget artistPage() => MaterialApp(
  home: ArtistDetailPage(
    artistId: BigInt.from(6452),
    name: '周杰伦',
    onPlaySongs: (_, _) {},
    loadArtist: (_) async => artistDetail(),
    loadSimilar: (_) async => const [],
    loadSongsPage: (_, _) async =>
        const rust.ArtistSongPageDto(songs: [], hasMore: false),
    loadMvsPage: (_, _) async =>
        const rust.ArtistMvPageDto(mvs: [], hasMore: false),
    loadDynamics: (_) async => const <rust.FeedEventDto>[],
  ),
);

Widget userPage() => MaterialApp(
  home: UserPage(
    userId: BigInt.from(1),
    loadProfile: (_) async => userDetail(),
    loadPlaylists: (_) async => const [],
  ),
);

void setView(WidgetTester tester, {double width = 360, double height = 800}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = Size(width, height);
  addTearDown(tester.view.reset);
}

/// 把 NestedScrollView 往上拖到顶栏收起(TabBar 钉住为止)。
Future<void> collapse(WidgetTester tester) async {
  await tester.drag(find.byType(Scrollable).first, const Offset(0, -1400));
  await tester.pumpAndSettle();
}

class Metrics {
  Metrics(this.banner, this.identity, this.tabBar);
  final Rect banner;
  final Rect identity;
  final Rect tabBar;
}

Future<Metrics> measure(WidgetTester tester) async {
  final banner = tester.getRect(find.byType(ProfileBannerImage));
  final identity = tester.getRect(find.byType(ProfileIdentity));
  await collapse(tester);
  final tabBar = tester.getRect(find.byType(TabBar));
  return Metrics(banner, identity, tabBar);
}

void main() {
  testWidgets('两页共用骨架: 横幅高度与身份卡位置完全一致', (tester) async {
    setView(tester);
    await tester.pumpWidget(artistPage());
    await tester.pumpAndSettle();
    final artist = await measure(tester);

    await tester.pumpWidget(userPage());
    await tester.pumpAndSettle();
    final user = await measure(tester);

    for (final m in [artist, user]) {
      expect(
        m.banner.height,
        kProfileBannerHeight,
        reason: '两页的横幅都必须是 kProfileBannerHeight',
      );
      // 身份卡贴在横幅下沿(不上浮, 不压图)
      expect(m.identity.top, closeTo(m.banner.bottom, 0.5));
    }
    expect(user.banner.height, artist.banner.height);
    expect(user.identity.top, closeTo(artist.identity.top, 0.5));
    // 身份卡高度允许不同(艺人用 headlineSmall 的名字), 但上沿与横幅关系必须一致
    expect(user.identity.left, artist.identity.left);
    expect(user.identity.width, artist.identity.width);
  });

  testWidgets('两页共用骨架: 收起后 pinned TabBar 在同一条线上', (tester) async {
    setView(tester);
    await tester.pumpWidget(artistPage());
    await tester.pumpAndSettle();
    final artist = await measure(tester);

    await tester.pumpWidget(userPage());
    await tester.pumpAndSettle();
    final user = await measure(tester);

    // 钉住: 顶栏收起后 TabBar 仍在视口顶部(而不是被内容顶走)
    expect(artist.tabBar.top, lessThan(kProfileBannerHeight));
    expect(user.tabBar.top, lessThan(kProfileBannerHeight));
    expect(user.tabBar.top, closeTo(artist.tabBar.top, 0.5));
    expect(user.tabBar.height, closeTo(artist.tabBar.height, 0.5));
  });

  testWidgets('统计 chip 统一: 艺人作品数在昵称下方, 用户账号统计在 footer', (tester) async {
    setView(tester);
    await tester.pumpWidget(artistPage());
    await tester.pumpAndSettle();
    // 需求 11: 作品数标签不再独占一行(footer), 改放身份卡昵称下方(meta 槽位),
    // 仍是同一套 ProfileStatChip 外观(ProfileWorksStatChip)。
    expect(find.byType(ProfileWorksStatChip), findsOneWidget);
    expect(find.byType(ProfileStatRow), findsNothing);
    expect(find.text('0 个专辑 · 2 首歌曲'), findsOneWidget);
    expect(find.text('关注'), findsOneWidget);

    await tester.pumpWidget(userPage());
    await tester.pumpAndSettle();
    expect(find.byType(ProfileStatRow), findsOneWidget);
    expect(find.text('关注 0'), findsOneWidget);
    expect(find.text('粉丝 0'), findsOneWidget);
    expect(find.text('Lv.8'), findsOneWidget);
  });

  testWidgets('300dp + 1.625 字号: 骨架不溢出', (tester) async {
    setView(tester, width: 300, height: 760);
    tester.platformDispatcher.textScaleFactorTestValue = 1.625;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(artistPage());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(userPage());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
