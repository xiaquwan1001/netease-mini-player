// 批次 C: 信息架构重排(设置瘦身 / 账号入口 3→1 / 推荐页 8→5 /
// 专辑 Dialog→全页 / 日推·最近听过 sheet→全页)的可达性回归。
// 每项被搬动/合并的功能至少一条「仍然可达」断言。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/album_preview.dart';
import 'package:minincm/src/discover.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/settings_account_page.dart';
import 'package:minincm/src/settings_view.dart';

/// 只覆盖测试里会碰到的 FFI 方法(歌单广场一进去就拉分类), 其余 noSuchMethod。
class _FakeRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<List<rust.PlaylistCategoryDto>> crateApiPlaylistCategories() async =>
      const [];

  @override
  Future<List<rust.PlaylistDto>> crateApiPlaylistsByCategory({
    required String cat,
    required int limit,
    required int offset,
  }) async =>
      const [];

  @override
  Future<List<rust.PlaylistDto>> crateApiHighQualityPlaylists({
    required String cat,
    required int limit,
  }) async =>
      const [];
}

rust.InitInfo info({bool loggedIn = true}) => rust.InitInfo(
      dataDir: '/tmp/minincm',
      deviceId: 'dev-1',
      loggedIn: loggedIn,
      vip: false,
      providers: const [],
    );

rust.AccountDto account(int id, String nickname, {bool active = false}) =>
    rust.AccountDto(
      userId: BigInt.from(id),
      nickname: nickname,
      active: active,
      vip: false,
    );

rust.SongDto song(int id, String name) => rust.SongDto(
      id: BigInt.from(id),
      name: name,
      artist: '歌手',
      artistId: BigInt.one,
      album: '专辑',
      albumId: BigInt.from(9),
      coverUrl: null,
      durationMs: BigInt.from(1000),
      fee: 0,
      vip: false,
      paid: false,
      playable: true,
    );

Widget host(Widget child) =>
    MaterialApp(home: Scaffold(body: Builder(builder: (_) => child)));

Widget pushHost(String label, VoidCallback onTap) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: onTap,
            child: Text(label),
          ),
        ),
      ),
    );

void big(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 3200);
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() {
    RustLib.initMock(api: _FakeRustApi());
  });

  // ---------------- 1) 设置瘦身 ----------------

  testWidgets('设置首页: 账号/会员/诊断/清空搜索历史已搬走, 只留分组入口+开关',
      (tester) async {
    big(tester);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsView(info: info()))),
    );
    await tester.pumpAndSettle();

    // 搬走的三组(审查 P1-7.9 / P1-7.11)
    expect(find.text('账号'), findsNothing);
    expect(find.text('会员'), findsNothing);
    expect(find.text('诊断'), findsNothing);
    expect(find.text('Rust 通道自检'), findsNothing);
    expect(find.text('清空搜索历史'), findsNothing);

    // 留下: 外观 / 行为开关 / 关于(含诊断二级页入口)
    expect(find.text('界面'), findsOneWidget);
    expect(find.text('通用'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('诊断与数据'), findsOneWidget);
    expect(find.text('切到搜索时清空上次结果'), findsOneWidget);
    expect(find.text('取链音质'), findsOneWidget);
  });

  testWidgets('设置 → 关于 → 诊断与数据: 二级页可达(自检/设备ID/数据目录)',
      (tester) async {
    big(tester);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SettingsView(info: info()))),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('诊断与数据'));
    await tester.pumpAndSettle();

    expect(find.text('Rust 通道自检'), findsOneWidget);
    expect(find.text('设备 ID'), findsOneWidget);
    expect(find.text('dev-1'), findsOneWidget);
    expect(find.text('数据目录'), findsOneWidget);
    expect(find.text('/tmp/minincm'), findsOneWidget);
  });

  // ---------------- 2) 账号入口 3→1 + 会员搬到「我的」 ----------------

  testWidgets('我的页: 资料头是账号入口, 黑胶会员入口也可达', (tester) async {
    big(tester);
    var accounts = 0;
    var vip = 0;
    await tester.pumpWidget(host(MineView(
      loggedIn: true,
      onLogin: () {},
      onOpenAccounts: () => accounts++,
      onOpenVip: () => vip++,
      onPlaySongs: (_, __) {},
      onOpenPlaylist: (_) {},
      onOpenPodcast: (_) {},
      onOpenAlbum: (_) {},
      onOpenRecent: () {},
      onOpenFollows: () async {},
      onOpenFolloweds: () async {},
      onOpenLiked: () {},
      loadLiked: () async => const [],
      loadPlaylists: () async => const [],
      loadPodcasts: () async => const [],
      loadAlbums: () async => const [],
      loadRecent: () async => const [],
      loadRanking: (_) async => const [],
    )));
    await tester.pumpAndSettle();

    // 资料头右上角药丸 → 账号页
    await tester.tap(find.text('账号管理'));
    await tester.pumpAndSettle();
    expect(accounts, 1);

    // 会员是账号资产, 从设置搬到「我的」(审查 P1-7.9)
    await tester.tap(find.text('黑胶会员'));
    expect(vip, 1);
  });

  testWidgets('账号与会员页: 账号簿/切换/忘记/添加/退出登录/会员 全部可达',
      (tester) async {
    big(tester);
    var logins = 0;
    var logouts = 0;
    var vip = 0;
    rust.AccountDto? switched;
    rust.AccountDto? removed;
    await tester.pumpWidget(pushHost('open', () {
      showAccountPage(
        tester.element(find.text('open')),
        info: info(),
        isAndroid: true,
        onLogin: () => logins++,
        onLogout: () async => logouts++,
        onOpenVip: () => vip++,
        loadAccounts: () async => [
          account(1, '小明', active: true),
          account(2, '小红'),
        ],
        onSwitchAccount: (a) async => switched = a,
        onRemoveAccount: (a) async => removed = a,
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('账号与会员'), findsOneWidget);

    // 账号簿: 切换
    await tester.tap(find.text('小红'));
    await tester.pumpAndSettle();
    expect(switched?.nickname, '小红');

    // 账号簿: 忘记
    await tester.tap(find.byTooltip('忘记这个账号').first);
    await tester.pumpAndSettle();
    expect(removed?.nickname, '小明');

    // 添加账号
    await tester.tap(find.text('添加账号'));
    expect(logins, 1);

    // 黑胶会员
    await tester.tap(find.text('黑胶会员'));
    expect(vip, 1);

    // 退出登录在账号页底部(原先在设置里, 审查 P1-7.10)
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(logouts, 1);
  });

  // ---------------- 3) 推荐页 8→5 ----------------

  Widget recommend({
    void Function()? onOpenNewRelease,
    void Function()? onOpenDaily,
  }) =>
      host(RecommendView(
        loggedIn: true,
        loadDailySongs: () async => [song(1, '每日一歌')],
        loadDailyPlaylists: () async => const [],
        loadPodcasts: () async => const [],
        loadFm: () async => const [],
        loadStyles: () async => const [
          rust.StyleTagDto(id: '1009', name: '粤语流行'),
        ],
        loadCharts: () async => [
          rust.ChartSummaryDto(
            id: BigInt.from(19723756),
            name: '飙升榜',
            coverUrl: null,
            updateFrequency: '刚刚更新',
            trackCount: BigInt.from(100),
            playCount: BigInt.from(1000),
          ),
        ],
        loadNewSongs: () async => [song(30, '新歌速递一')],
        loadNewAlbums: () async => [
          rust.AlbumItemDto(
            id: BigInt.from(40),
            name: '新碟A',
            coverUrl: null,
            artist: '歌手',
            trackCount: BigInt.from(8),
          ),
        ],
        onOpenAlbum: (_) {},
        onOpenNewRelease: onOpenNewRelease,
        onPlaySongs: (_, __) {},
        onOpenPlaylist: (_) {},
        onOpenPodcast: (_) {},
        onHeartMode: () {},
        onOpenDaily: onOpenDaily ?? () {},
      ));

  testWidgets('推荐页: 平级区块 8→5(每日推荐/排行榜/推荐歌单/新歌新碟/推荐播客)',
      (tester) async {
    big(tester);
    await tester.pumpWidget(recommend());
    await tester.pumpAndSettle();

    // 合并后的 5 个区块标题(快捷区是三张卡, 没有标题)
    expect(find.text('每日推荐'), findsNWidgets(2)); // 快捷卡 + 区块标题
    expect(find.text('排行榜'), findsOneWidget);
    expect(find.text('推荐歌单'), findsOneWidget);
    expect(find.text('新歌新碟'), findsOneWidget);
    expect(find.text('推荐播客'), findsOneWidget);

    // 被合并掉的两个区块标题不再单独作为区块存在
    expect(find.text('每日推荐歌曲'), findsNothing);
    expect(find.text('歌单广场'), findsNothing); // 游离按钮已提到 header

    // 新歌/新碟 降为同一区块内的两个小标题, 内容仍可达
    expect(find.text('新歌速递'), findsOneWidget);
    expect(find.text('新歌速递一'), findsOneWidget);
    expect(find.text('新碟上架'), findsOneWidget);
    expect(find.text('新碟A'), findsOneWidget);
  });

  testWidgets('推荐页: 风格推荐下沉为排行榜区块内的 chips, 仍在榜单元块之后',
      (tester) async {
    big(tester);
    await tester.pumpWidget(recommend());
    await tester.pumpAndSettle();

    expect(find.text('风格推荐'), findsOneWidget);
    expect(find.text('粤语流行'), findsOneWidget);
    // 下沉: 风格 chip 排在榜单封面之后(同一区块内次级内容)
    final chartDy = tester.getTopLeft(find.text('飙升榜')).dy;
    final styleDy = tester.getTopLeft(find.text('粤语流行')).dy;
    expect(styleDy, greaterThan(chartDy));
    // 且不再位于「每日推荐」区块之前(区块顺序: 每日推荐 → 排行榜+风格)
    final dailyDy = tester.getTopLeft(find.text('每日一歌')).dy;
    expect(chartDy, greaterThan(dailyDy));
  });

  testWidgets('推荐页: 新歌新碟 合并后唯一的「全部」仍进分类页', (tester) async {
    big(tester);
    var more = 0;
    await tester.pumpWidget(recommend(onOpenNewRelease: () => more++));
    await tester.pumpAndSettle();

    // 5 个「全部」: 每日推荐 / 排行榜 / 推荐歌单 / 新歌新碟 / 推荐播客
    expect(find.text('全部'), findsNWidgets(5));
    await tester.tap(find.text('全部').at(3));
    await tester.pumpAndSettle();
    expect(more, 1);
  });

  testWidgets('推荐页: 推荐歌单 标题右侧「全部」进歌单广场(原游离按钮的功能)',
      (tester) async {
    big(tester);
    await tester.pumpWidget(recommend());
    await tester.pumpAndSettle();

    await tester.tap(find.text('全部').at(2));
    await tester.pumpAndSettle();
    expect(find.text('歌单广场'), findsOneWidget);
  });

  // ---------------- 4) 专辑详情 Dialog → 全页 ----------------

  testWidgets('专辑详情是全页 Scaffold(可返回), 点曲目仍回调整张专辑', (tester) async {
    big(tester);
    List<rust.SongDto>? played;
    int? playedIndex;
    await tester.pumpWidget(pushHost('open', () {
      showAlbumPreview(
        tester.element(find.text('open')),
        albumId: BigInt.from(9),
        onPlay: (songs, i) {
          played = songs;
          playedIndex = i;
        },
        loadAlbum: (_) async => rust.AlbumDetailDto(
          id: BigInt.from(9),
          name: '叶惠美',
          coverUrl: null,
          artist: '周杰伦',
          description: '经典',
          songs: [song(1, '以父之名'), song(2, '晴天')],
        ),
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 全页: 有 AppBar, 不再是 Dialog
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    // 返回键可回到上一页
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(find.text('以父之名'), findsNothing);

    // 再进一次, 点曲目 → 回调整张专辑(语义不变)
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('晴天'));
    await tester.pumpAndSettle();
    expect(played?.length, 2);
    expect(playedIndex, 1);
    expect(find.text('open'), findsOneWidget);
  });

  // ---------------- 5) 日推 / 最近听过 sheet → 全页 ----------------

  testWidgets('每日推荐是全页(不是 sheet); 历史日推用返回键退回日期列表', (tester) async {
    big(tester);
    await tester.pumpWidget(pushHost('open', () {
      showDiscoverPage(
        tester.element(find.text('open')),
        onPlaySongs: (_, __) {},
        onOpenPlaylist: (_) {},
        loadSongs: () async => [song(1, '晴天')],
        loadPlaylists: () async => const [],
        loadHistoryDates: () async => ['2024-06-20', '2024-06-19'],
        loadHistorySongs: (date) async => [song(7, '$date 的歌')],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 全页: 没有 BottomSheet, 有 AppBar
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('每日推荐'), findsOneWidget);

    await tester.tap(find.text('历史日推'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2024-06-20'));
    await tester.pumpAndSettle();
    expect(find.text('2024-06-20 的日推'), findsOneWidget);

    // 审查 P1-7.14: 系统返回/AppBar 返回先退回日期列表, 不关整页
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('2024-06-20 的日推'), findsNothing);
    expect(find.text('2024-06-19'), findsOneWidget);
    expect(find.text('每日推荐'), findsOneWidget);
  });

  testWidgets('最近听过是全页(4 个 tab), 不再是 72% 高的 sheet', (tester) async {
    big(tester);
    await tester.pumpWidget(pushHost('open', () {
      showRecentPage(
        tester.element(find.text('open')),
        onPlay: (_, __) {},
        loadRecent: () async => [song(3, '最近一首')],
        loadAlbums: () async => const [],
        loadPlaylists: () async => const [],
        loadPodcasts: () async => const [],
      );
    }));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('最近听过'), findsOneWidget);
    expect(find.text('单曲'), findsOneWidget);
    expect(find.text('专辑'), findsOneWidget);
    expect(find.text('歌单'), findsOneWidget);
    expect(find.text('播客'), findsOneWidget);
    expect(find.text('最近一首'), findsOneWidget);
  });
}
