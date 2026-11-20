// Golden(视觉回归)基准: 9 个高价值页面的整屏排版快照。
//
// 为什么需要: 现有 widget 测试只断言"某段文本存在/不溢出", 改动 A 页面把 B 的
// 间距、换行、留白挤坏时全都测不出来。这里把整屏像素锁成基准图, 布局回归直接变红。
//
// 运行前提(重要):
//   * cwd 必须是 `ui/`(`matchesGoldenFile` 的路径按测试文件目录解析, 字体探测
//     也依赖本机绝对路径);
//   * golden 只在 Linux 上生成与校验 —— 字体文件、Skia 版本、抗锯齿在不同平台/
//     不同 Flutter 版本间都有差异, 换机或升级 Flutter 后需 `--update-goldens` 重出
//     基准, 否则会大面积假失败。
//   * CI 已接入(CI 里唯一跑 golden 的地方是 flutter 测试 job): 渲染环境靠
//     `fonts-noto-cjk` + 固定 Flutter 3.47.9 与本地对齐, 命令是
//     `flutter test --exclude-tags network`(只排联网 smoke)。
//
// 字体: flutter_test 的默认字体(FlutterTest)没有 CJK 字形, 中文会被画成方块,
// golden 就失去意义。所以 setUpAll 里探测系统 CJK 字体, 用 FontLoader 注册后设成
// 默认 fontFamily。探测不到时**不静默**: 打印告警并退化为默认字体(那时图里的中文
// 就是方块, 一眼可见)。
//
// 视口口径(两条, 覆盖"常规"与"项目最严"): 360x800 @1.0 字号; 300x640 @1.25 字号。
// 后者对齐 test/narrow_width_audit_test.dart 的 pumpNarrow 口径(300dp + 1.25 字
// 号 = vivo 真机 1440x3168 @768dpi + 系统字号 1.25 的实际渲染条件)。
//
// 稳定性: 所有页面数据都走注入的假 loader(0 网络); 封面/头像一律 coverUrl: null
// 走占位图; 无限动画(跑马灯/加载圈)用固定帧数推进代替 pumpAndSettle, 见 _pumpFrames。
//
// 页面清单(9 页 x 2 视口 = 18 张 + 宽档 3 张: 歌单详情双列 / 播客详情双列 /
// 主从分栏): 设置 / 账号管理 / 推荐 / 我的 / 搜索落地 /
// 消息中心 / 歌单详情 / 艺人页 / 动态流。后三页是 churn top-10 里最容易连带回归的
// 三块(2026-11 前端审计建议 11): 歌单详情改行距会挤坏曲目行, 艺人页改信息区会挤坏
// tab 行, 动态流改卡片会挤坏顶部分类条。其中歌单详情只有命令式入口(页面私有 +
// 数据直连 FFI), 靠 _RouteHost 推路由 + _GoldenRustApi 垫数据才拿得到"正常态"。
//
// 门禁口径: 标 @Tags(['golden']) —— CI 与本地都跑(CI 侧先装 fonts-noto-cjk,
// 见 .github/workflows/ci.yml / .gitlab-ci.yml)。本机没有 CJK 字体时用例自动 skip
// 并给出安装提示, 不会红; CI 上字体装不上就会整组 skip, 所以 workflow 里把装字体
// 单独做成一步, 失败即整条 job 红, 不会静默丢覆盖率。
@Tags(['golden'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/artist_page.dart';
import 'package:minincm/src/detail/playlist_detail_page.dart';
import 'package:minincm/src/detail/podcast_detail_page.dart';
import 'package:minincm/src/detail_pane.dart'
    show
        DetailPaneSplit,
        attachDetailPaneHost,
        detachDetailPaneHost,
        detailPaneSlot;
import 'package:minincm/src/feed_view.dart';
import 'package:minincm/src/layout.dart' show ContentWidthLimit;
import 'package:minincm/src/messages_page.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart' show RustLib, RustLibApi;
import 'package:minincm/src/search_landing.dart';
import 'package:minincm/src/search_results.dart';
import 'package:minincm/src/settings_account_page.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/theme.dart';

import 'support/fakes.dart';

// ---------------------------------------------------------------- 字体

/// FontLoader 注册用的家族名。页面自己的 fontFamily 是 null, 靠 theme 里的
/// textTheme.apply(fontFamily:) 把整棵树都指到这个家族上。
const String _kGoldenFontFamily = 'GoldenCJK';

/// 按优先级探测系统 CJK 字体: Noto Sans CJK 优先(字形最全且与安卓默认一致),
/// 其次文泉驿/思源。找不到就退化(见文件头)。
const List<String> _cjkFontCandidates = <String>[
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc',
  '/usr/share/fonts/opentype/noto/NotoSansCJK-Medium.ttc',
  '/usr/share/fonts/opentype/noto/NotoSansSC-Regular.otf',
  '/usr/share/fonts/opentype/noto/NotoSansSC-Regular.ttc',
  '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
  '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc',
  '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
];

/// 探测并注册字体, 返回命中的文件路径(未命中返回 null).
///
/// 注意 .ttc 是字体集合, FontLoader 只会取其中第 0 个 face(Noto 系列是 JP),
/// 中文常用字在 JP face 的 cmap 里都有(实测本文件用到的字符 0 缺失), 只是少数字
/// 的字形是日式写法; 想要纯 SC 字形就装单 face 的 NotoSansSC*.otf(上面已列候选)。
Future<String?> _loadGoldenFont() async {
  for (final path in _cjkFontCandidates) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      final bytes = await file.readAsBytes();
      final loader = FontLoader(_kGoldenFontFamily)
        ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
      await loader.load();
      return path;
    } catch (error) {
      debugPrint('golden: 加载字体 $path 失败, 继续试下一个: $error');
    }
  }
  return null;
}

// ---------------------------------------------------------------- 主题/取景

/// 页面用浅色主题(与 app 默认一致), 并把 textTheme 整体指到 CJK 字体.
///
/// 为什么要 apply 到 textTheme: 页面里的文字绝大多数取自 `theme.textTheme.*`,
/// 只设 MaterialApp 的 fontFamily 管不到这些显式 style。
ThemeData _goldenTheme() {
  final base = buildLightTheme();
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _kGoldenFontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: _kGoldenFontFamily,
    ),
  );
}

/// golden 截图的锚点: 显式包一层 RepaintBoundary, 保证截到的是整个视口
/// (而不是就近某个内部 boundary), 也不受 Scaffold/AppBar 内部结构变化影响。
const ValueKey<String> _kGoldenRootKey = ValueKey<String>('golden-root');

/// 固定帧数推进。
///
/// 为什么不用 pumpAndSettle: 页面里有无限动画(长标题跑马灯、加载圈、骨架屏),
/// pumpAndSettle 会超时; 而"推进固定帧数"同时保证每次运行落在同一动画相位,
/// 否则同一份基准图会随机抖动。
Future<void> _pumpFrames(WidgetTester tester, {int frames = 12}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 把 [page] 放进 MaterialApp, 按给定逻辑尺寸/字号铺满视口并稳定下来.
Future<void> _pumpPage(
  WidgetTester tester,
  Widget page, {
  required Size size,
  double textScale = 1.0,
  int frames = 12,
  bool contentLimit = false,
}) async {
  tester.view.physicalSize = size;
  // dpr 固定 1.0: 逻辑像素 == 物理像素, 基准图小(360x800)且不受设备密度影响
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final theme = _goldenTheme();
  await tester.pumpWidget(
    RepaintBoundary(
      key: _kGoldenRootKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme,
        themeMode: ThemeMode.light,
        // 字号走 MediaQuery 而不是 platformDispatcher.textScaleFactorTestValue,
        // 与 narrow_width_audit_test 的 pumpNarrow 保持同一口径。
        //
        // 必须放 MaterialApp.builder(它包住 Navigator)而不是包在 home 里:
        // Navigator 在 home 之上, 只包 home 管不到 push 出来的路由页(歌单详情
        // 就是这么进去的), 那些页面会退回 1.0 字号 —— 窄屏基准就测不到东西。
        builder: (context, child) {
          // contentLimit: 宽档基准要带上真实壳层的内容限宽(840 居中), 否则
          // 1280 窗口下页面会按整窗排版, 双列右栏变成 968 —— 不是线上几何。
          final content = contentLimit
              ? ContentWidthLimit(child: child!)
              : child!;
          if (textScale == 1.0) return content;
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(textScaler: TextScaler.linear(textScale)),
            child: content,
          );
        },
        home: page,
      ),
    ),
  );
  await _pumpFrames(tester, frames: frames);
}

Future<void> _expectGolden(WidgetTester tester, String name) async {
  // 防止把"报错/未接线"的中间态锁成基准: ErrorWidget 或"加载失败"文案一旦出现,
  // 说明某个假 loader 没接上(页面回落到了真实 rust 调用), 此时基准图没有意义。
  expect(find.byType(ErrorWidget), findsNothing, reason: '$name 渲染出错');
  expect(find.textContaining('加载失败'), findsNothing, reason: '$name 有区块加载失败');
  await expectLater(
    find.byKey(_kGoldenRootKey),
    matchesGoldenFile('goldens/$name.png'),
  );
}

// ---------------------------------------------------------------- 假数据(0 网络)

/// 诊断二级页要展示设备 ID/数据目录, 设置页的"账号管理"行也读 loggedIn;
/// 全部写死成常量, 避免基准图里混进真实设备信息。
rust.InitInfo _info({bool loggedIn = true}) => rust.InitInfo(
  dataDir: '/tmp/minincm-golden',
  deviceId: 'golden-device-0001',
  loggedIn: loggedIn,
  vip: loggedIn,
  providers: const <rust.ProviderInfo>[],
);

rust.AccountDto _account(
  int id,
  String nickname, {
  bool active = false,
  bool vip = false,
}) => rust.AccountDto(
  userId: BigInt.from(id),
  nickname: nickname,
  active: active,
  vip: vip,
);

/// 封面一律 null ⇒ 走占位图, 测试里不会发任何网络请求。
/// 共享工厂 + golden 基准口径(专辑名固定, 时长 4:29)。
rust.SongDto _song(int id, String name, {String artist = '艺人'}) => fakeSong(
  id: id,
  name: name,
  artist: artist,
  album: '专辑名',
  durationMs: 269000,
);

/// 共享工厂 + golden 基准口径(12 首歌单 / 主播名 8 期电台)。
rust.Playlist _playlist(int id, String name) =>
    fakePlaylist(id: id, name: name, trackCount: 12);

rust.PodcastRadio _radio(int id, String name) =>
    fakeRadio(id: id, name: name, djName: '主播名', programCount: 8);

rust.AlbumItem _album(int id, String name) => rust.AlbumItem(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  artist: '艺人',
  trackCount: BigInt.from(10),
);

rust.MessageCountsDto _counts({
  int private = 2,
  int notices = 1,
  int comments = 3,
  int forwards = 0,
}) => rust.MessageCountsDto(
  private: private,
  notices: notices,
  comments: comments,
  forwards: forwards,
  total: private + notices + comments + forwards,
);

rust.PrivateSession _session(int uid, String name, String last, int unread) =>
    rust.PrivateSession(
      userId: BigInt.from(uid),
      nickname: name,
      avatarUrl: null,
      lastMessage: last,
      lastTimeMs: BigInt.from(1700000000000),
      unread: unread,
    );

rust.InboxItem _inbox(int id, String kind, String actor, String text) =>
    rust.InboxItem(
      id: BigInt.from(id),
      kind: kind,
      actor: actor,
      avatarUrl: null,
      text: text,
      detail: '我喜欢的音乐',
      timeMs: BigInt.from(1700000000000),
    );

rust.HotSearchTerm _hot(int rank, String keyword) =>
    rust.HotSearchTerm(rank: rank, keyword: keyword);

// ---------------------------------------------------------------- 假 FFI 通道

/// 歌单详情页(`showPlaylistDetail`)只有命令式入口: 页面本身是私有类, 详情/曲目/
/// 评论/当前 uid 全部直连 FFI, 没有任何 loader 注入点。不垫这一层, 基准图就是空壳
/// 或错误态, 当不了回归探针。
///
/// 只覆盖歌单详情会调到的 5 个方法; 其余一律抛 —— 与"没 init 过 RustLib"时的行为
/// 一致(那时也抛), 所以不会把"某处漏接线"悄悄变成正常态。
class _GoldenRustApi implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('golden 未覆盖 ${invocation.memberName}');

  /// 当前账号 uid: 故意不等于歌单创建者, 于是详情页不出现"管理"菜单
  /// (编辑/移出曲目/删除属于另一条排版分支, 不进这张基准图)。
  @override
  Future<BigInt> crateApiSocialMyUid() async => BigInt.from(1822714196);

  @override
  Future<rust.PlaylistDetail> crateApiDetailPlaylistDetail({
    required BigInt playlistId,
  }) async => _playlistDetail;

  @override
  Future<List<rust.SongDto>> crateApiLibraryPlaylistSongs({
    required BigInt playlistId,
  }) async => _playlistSongs();

  /// 播客详情的节目列表(S2 宽档双列基准用)
  @override
  Future<List<rust.PodcastProgramDto>> crateApiPodcastPodcastPrograms({
    required BigInt radioId,
    required int limit,
    required int offset,
  }) async => _podcastPrograms(radioId);

  @override
  Future<rust.CommentPage> crateApiDetailComments({
    required String kind,
    required BigInt resourceId,
    required int limit,
    required int offset,
  }) async => rust.CommentPage(
    threadId: 'A_PL_0_24381616',
    comments: _goldenComments(),
    total: BigInt.from(2),
    hasMore: false,
  );

  @override
  Future<rust.CommentStats> crateApiDetailCommentStats({
    required String threadId,
  }) async => rust.CommentStats(
    threadId: threadId,
    resourceId: BigInt.from(24381616),
    commentCount: BigInt.from(88),
    commentCountDesc: '88',
    shareCount: BigInt.from(340),
    likedCount: BigInt.zero,
    liked: false,
    musicianSaidCount: BigInt.zero,
    commentUpgraded: false,
  );
}

/// 歌单详情头部: 五位数播放量/收藏数 + 两个标签 + 一句简介, 已收藏(subscribed)。
final rust.PlaylistDetail _playlistDetail = rust.PlaylistDetail(
  id: BigInt.from(24381616),
  name: '华语流行精选',
  coverUrl: null,
  description: '每日更新的华语流行精选, 收录本周最热单曲。',
  creatorName: '云音乐编辑部',
  creatorId: BigInt.from(999999999),
  trackCount: BigInt.from(12),
  playCount: BigInt.from(128000),
  subscribed: true,
  subscribedCount: BigInt.from(52000),
  shareCount: BigInt.from(340),
  commentCount: BigInt.from(88),
  tags: const <String>['华语', '流行'],
);

/// 播客详情头部: 8 个节目 / 52.3 万次播放 / 主播名 / 一句简介。
final rust.PodcastRadio _podcastRadio = rust.PodcastRadio(
  id: BigInt.from(42666),
  name: '硬地电台',
  coverUrl: null,
  description: '独立音乐人的访谈与现场, 每周一期。',
  djName: '主播小林',
  programCount: BigInt.from(8),
  playCount: BigInt.from(523000),
);

/// 8 集节目: 奇数集正在播(第 1 集 song.id == 701), 时长 30 分钟。
List<rust.PodcastProgramDto> _podcastPrograms(BigInt radioId) =>
    <rust.PodcastProgramDto>[
      for (var i = 1; i <= 8; i++)
        rust.PodcastProgramDto(
          id: BigInt.from(900 + i),
          name: '第 $i 期 · 独立音乐现场',
          coverUrl: null,
          durationMs: BigInt.from(1800000),
          djName: '主播小林',
          radioId: radioId,
          radioName: '硬地电台',
          description: '本期聊独立音乐。',
          song: _song(700 + i, '第 $i 期 · 独立音乐现场'),
        ),
    ];

/// 12 首曲目: 奇数/偶数行艺人换人, "艺人 · 专辑"两个字段都非空。
List<rust.SongDto> _playlistSongs() => <rust.SongDto>[
  for (var i = 1; i <= 12; i++)
    _song(500 + i, '华语热歌$i', artist: i.isOdd ? '周杰伦' : '林俊杰'),
];

/// 评论区(在首屏之外): 存在的意义是"评论区不是错误态", 而不是锁定它的排版。
List<rust.Comment> _goldenComments() => <rust.Comment>[
  rust.Comment(
    id: BigInt.from(90001),
    userId: BigInt.from(1822714196),
    userName: '小明',
    content: '这张歌单我循环了一整周, 选曲比官方推荐靠谱。',
    timeMs: BigInt.from(1700000000000),
    likedCount: BigInt.from(12),
    liked: false,
    replyCount: BigInt.zero,
    ipLocation: '广东',
    hot: true,
    parentId: BigInt.zero,
  ),
  rust.Comment(
    id: BigInt.from(90002),
    userId: BigInt.from(90003),
    userName: '小红',
    content: '第 3 首是什么歌?',
    timeMs: BigInt.from(1700000000000),
    likedCount: BigInt.from(3),
    liked: false,
    replyCount: BigInt.zero,
    ipLocation: '浙江',
    hot: false,
    parentId: BigInt.zero,
  ),
];

// ---------------------------------------------------------------- 被测页面

/// 一个 golden 目标: 名字进文件名, build 每次调用都产出全新的 widget(避免状态串味).
class _GoldenPage {
  const _GoldenPage(this.name, this.build, {this.frames = 12});

  final String name;
  final Widget Function() build;

  /// 固定推进的帧数(见 [_pumpFrames])。默认 12 帧 = 600ms 够静态页面用;
  /// 推路由的页面还要额外等 300ms 转场 + 路由页自己的数据回来, 给到 24 帧。
  final int frames;
}

Widget _settingsPage() => Scaffold(
  appBar: AppBar(title: const Text('设置')),
  // onOpenAccounts 传了才会出现"账号管理"卡片, 让基准图覆盖这一行
  body: SettingsView(info: _info(), onOpenAccounts: () {}),
);

Widget _accountPage() => AccountPage(
  info: _info(),
  isAndroid: false,
  onLogin: () {},
  onLogout: () async {},
  loadAccounts: () async => <rust.AccountDto>[
    _account(1822714196, '下去玩', active: true, vip: true),
    _account(90001, '小号'),
  ],
);

Widget _recommendPage() => Scaffold(
  appBar: AppBar(title: const Text('推荐')),
  body: RecommendView(
    loggedIn: true,
    loadDailySongs: () async => <rust.SongDto>[
      _song(1, '每日推荐一', artist: '周杰伦'),
      _song(2, '每日推荐二'),
    ],
    loadDailyPlaylists: () async => <rust.Playlist>[
      _playlist(10, '华语流行精选'),
      _playlist(11, '深夜电台'),
    ],
    loadPodcasts: () async => <rust.PodcastRadio>[_radio(20, '睡前播客')],
    loadFm: () async => <rust.SongDto>[_song(3, '私人 FM 曲目')],
    loadStyles: () async => const <rust.StyleTag>[
      rust.StyleTag(id: '1009', name: '粤语流行'),
      rust.StyleTag(id: '1020', name: '华语流行'),
      rust.StyleTag(id: '3000', name: '轻音乐'),
    ],
    loadNewSongs: () async => <rust.SongDto>[_song(30, '新歌速递一')],
    loadNewAlbums: () async => <rust.AlbumItem>[_album(40, '新碟上架一')],
    onOpenAlbum: (_) {},
    onOpenNewRelease: () {},

    onOpenPlaylist: (_) {},
    onOpenPodcast: (_) {},
    onHeartMode: () {},
    onOpenDaily: () {},
  ),
);

Widget _minePage() => Scaffold(
  appBar: AppBar(title: const Text('我的')),
  body: MineView(
    loggedIn: true,
    onLogin: () {},
    onOpenAccounts: () {},
    onOpenMessages: () {},
    onOpenVip: () {},
    onOpenMedals: () {},
    loadMessageCounts: () async => _counts(),
    loadProfile: () async => rust.ProfileDetail(
      userId: BigInt.from(1822714196),
      nickname: '下去玩',
      avatarUrl: null,
      backgroundUrl: null,
      signature: '轻音 MiniNCM · 这里是签名',
      vip: true,
      follows: BigInt.from(128),
      followeds: BigInt.from(64),
      level: BigInt.from(9),
    ),
    // 用户反馈 15: 「我的动态」区块已并入「我的主页」, 这一页不再有动态预览,
    // 所以 golden 里也不再注入动态数据(注入点本身已从 MineView 删除).
    loadLiked: () async => <rust.SongDto>[_song(1, '我喜欢的歌')],
    loadPlaylists: () async => <rust.Playlist>[_playlist(2, '收藏的歌单')],
    loadPodcasts: () async => <rust.PodcastRadio>[_radio(3, '收藏的播客')],
    loadAlbums: () async => <rust.AlbumItem>[_album(4, '收藏的专辑')],
    loadRecent: () async => <rust.SongDto>[_song(7, '最近播放的歌')],
    loadRanking: (period) async => <rust.PlayRankEntryDto>[
      rust.PlayRankEntryDto(
        song: _song(
          period == 'week' ? 9 : 8,
          period == 'week' ? '本周常听' : '最常听',
        ),
        playCount: BigInt.from(period == 'week' ? 3 : 42),
        score: BigInt.from(period == 'week' ? 30 : 420),
      ),
    ],

    onOpenPlaylist: (_) {},
    onOpenPodcast: (_) {},
    onOpenAlbum: (_) {},
    onOpenLiked: () {},
    onOpenRecent: () {},
    onOpenFollows: () async {},
    onOpenFolloweds: () async {},
  ),
);

Widget _searchLandingPage() => Scaffold(
  body: SearchLanding(
    history: const <String>['七里香', '晴天', '周杰伦'],
    hot: <rust.HotSearchTerm>[
      _hot(1, '晴天'),
      _hot(2, '稻香'),
      _hot(3, '七里香'),
      _hot(4, '夜曲'),
    ],
    recommended: const [RecommendedKeyword(keyword: '周杰伦')],
    onSelected: (_) {},
    onClearHistory: () {},
  ),
);

/// 消息中心: 三个页签(带未读角标)+ 会话列表, loader 全部可注入。
/// (2026-11 审计建议 11 之后歌单详情页也进了基准, 走 _RouteHost + _GoldenRustApi,
/// 见 [_playlistDetailPage]; 这里原先"歌单详情不适合做整屏基准"的结论已作废。
Widget _messagesPage() => MessagesPage(
  loadCounts: () async => _counts(),
  loadSessions: (limit, offset) async => <rust.PrivateSession>[
    _session(7, '云音乐VIP', '本月等级权益已更新', 3),
    _session(8, '小明', '晚点聊', 0),
  ],
  loadHistory: (uid, limit, before) async => <rust.PrivateMessage>[],
  loadNotices: () async => <rust.InboxItem>[
    _inbox(1, 'notice', '小明', '赞了你的主页背景'),
    _inbox(2, 'notice', '小红', '关注了你'),
  ],
  loadComments: () async => <rust.InboxItem>[
    _inbox(3, 'comment', '小红', '来了来了'),
    _inbox(4, 'comment', '小明', '好听'),
  ],
);

// ---------------------------------------------------------------- 后补三页

/// "只能从命令式入口进入"的页面的壳: 首帧后 push 一条普通路由, 之后照常推进固定帧数
/// (见 _GoldenPage.frames —— 转场 300ms + 路由页自己的数据要时间落位)。
/// 截图锚点仍是 _kGoldenRootKey 那个 RepaintBoundary, 路由页画在它内部。
class _RouteHost extends StatefulWidget {
  const _RouteHost({required this.open});

  final void Function(BuildContext context) open;

  @override
  State<_RouteHost> createState() => _RouteHostState();
}

class _RouteHostState extends State<_RouteHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.open(context);
    });
  }

  /// 只占一帧空壳, 真正的页面在首帧之后由路由压上来
  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

/// 基准图: playlist_detail_360x800.png / playlist_detail_300x640_s125.png /
/// playlist_detail_1280x720.png(宽档双列, 见下面单独那条用例)。
///
/// 应有什么: 头部卡片(标题「华语流行精选」/ 创建者 / 「12 首 · 播放 128000 次」/
/// 华语·流行 两个标签 / 一句简介 + 「展开」) → 「筛选本页曲目」输入框与
/// 「定位正在播放」→ 曲目行(第 1 行是正在播放高亮, 其余是「序号 歌名 / 艺人 · 专辑 /
/// 04:29 + 红心); 收藏态为已收藏(实心红心), 创建者不是自己(所以没有"管理"菜单)。
///
/// 坏在哪: 头部卡片整块消失 / 曲目行只剩骨架 / 整屏变错误态, 都属于内容坏(不是
/// 像素抖动); 只是间距变了才是真的"布局回归"。
Widget _playlistDetailPage() => _RouteHost(
  open: (context) {
    unawaited(
      showPlaylistDetail(
        context,
        playlistId: BigInt.from(24381616),
        name: '华语流行精选',
        loggedIn: true,
        currentTrackId: BigInt.from(501),
        currentPlaylistId: BigInt.from(24381616),
      ),
    );
  },
);

/// 基准图: podcast_detail_1280x720.png(宽档双列, 方案 A · S2)。
///
/// 与歌单详情同构: 左 300 一列只有播客信息卡(封面 120 / 标题 / 主播 /
/// 「8 个节目 · 播放 523000 次」/ 简介), 右 528 一列是「筛选节目」输入框 + 8 行节目
/// (第 1 行正在播放高亮) + 评论。只锁宽档双列这一张, 窄档由
/// test/podcast_detail_two_column_test.dart 的矩形断言覆盖。
///
/// 坏在哪: 两栏宽度/间距偏 1dp 以上、左栏混进节目行、只剩一列。
/// 以后动 kContentMaxWidth / kTwoColumnListWidth / kTwoColumnGap 都要重出这一张。
Widget _podcastDetailPage() => _RouteHost(
  open: (context) {
    unawaited(
      showPodcastDetail(
        context,
        radio: _podcastRadio,
        // 单集详情弹层用的 loader: 基准图不打开弹层, 给一个可用实现即可
        loadProgramDetail: (id) async =>
            _podcastPrograms(_podcastRadio.id).firstWhere((p) => p.id == id),
      ),
    );
  },
);

/// 主从分栏(方案 B · S4)的基准图宿主: 左栏 = 搜索结果的歌单网格, 右栏 = 歌单详情
/// 内嵌形态。与生产同一条装配(ContentWidthLimit 840 + DetailPaneSplit + openDetail
/// 的宽档分支), 只是左栏用 SearchResultsView 直接喂假 bundle(整页 HomePage 的搜索链路
/// 已由 test/master_detail_flow_test.dart 端到端覆盖)。
class _MasterDetailGoldenHost extends StatefulWidget {
  const _MasterDetailGoldenHost();

  @override
  State<_MasterDetailGoldenHost> createState() =>
      _MasterDetailGoldenHostState();
}

class _MasterDetailGoldenHostState extends State<_MasterDetailGoldenHost> {
  @override
  void initState() {
    super.initState();
    attachDetailPaneHost();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 宽档 + 根路由 + 宿主在场 ⇒ 填右栏(不 push)
      unawaited(
        showPlaylistDetail(
          context,
          playlistId: BigInt.from(24381616),
          name: '华语流行精选',
          loggedIn: true,
          currentTrackId: BigInt.from(501),
          currentPlaylistId: BigInt.from(24381616),
        ),
      );
    });
  }

  @override
  void dispose() {
    detachDetailPaneHost();
    detailPaneSlot.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: DetailPaneSplit(
      master: (context, selectedKey) => SearchResultsView(
        bundle: _searchPlaylistBundle(),
        liked: const <BigInt>{},
        currentTrackId: null,
        onPlaySong: (_) {},
        onOpenArtist: (_) {},
        onOpenAlbum: (_) {},
        onOpenPlaylist: (_) {},
        onOpenPodcast: (_) {},
        selectedPlaylistId: selectedKey is BigInt ? selectedKey : null,
      ),
    ),
  );
}

/// 只有歌单分区有数据 ⇒ 分类条自动停在「歌单」(与真实搜索结果的首屏一致)。
rust.SearchBundleDto _searchPlaylistBundle() => rust.SearchBundleDto(
  songs: const <rust.SongDto>[],
  songTotal: BigInt.zero,
  artists: const <rust.SearchArtist>[],
  albums: const <rust.SearchAlbum>[],
  playlists: <rust.SearchPlaylistItem>[
    rust.SearchPlaylistItem(
      id: BigInt.from(24381616),
      name: '华语流行精选',
      coverUrl: null,
      creatorName: '云音乐编辑部',
      trackCount: BigInt.from(12),
      playCount: BigInt.from(128000),
    ),
    for (var i = 2; i <= 6; i++)
      rust.SearchPlaylistItem(
        id: BigInt.from(24381610 + i),
        name: '华语精选$i',
        coverUrl: null,
        creatorName: '云音乐编辑部',
        trackCount: BigInt.from(20 + i),
        playCount: BigInt.from(10000 * i),
      ),
  ],
  podcasts: const <rust.SearchPodcast>[],
  users: const <rust.UserItem>[],
  mvs: const <rust.MvItem>[],
);

/// 基准图: artist_360x800.png / artist_300x640_s125.png。
///
/// 应有什么: 整宽横幅 → 身份卡(周杰伦 / 别名 Jay Chou / 「关注」/ 粉丝 1922.7万 /
/// 32 个专辑 · 379 首歌曲) → 简介与相似艺人两块信息区 → 4 个 tab(推荐单曲 / 全部歌曲 /
/// 专辑 / 动态,) → 首屏停在「推荐单曲」的 3 行曲目。
///
/// 坏在哪: tab 行被挤掉或竖溢、粉丝/作品数被截断、横幅高度跳变, 都是这一页最典型的
/// 回归; 只剩 loading 骨架说明 _loadArtist 没接上。
Widget _artistPage() => ArtistDetailPage(
  artistId: BigInt.from(6452),
  name: '周杰伦',

  onOpenAlbum: (_, _, _) {},
  onOpenUrl: (_) async {},
  loadArtist: (_) async => _artistDetail(),
  loadSimilar: (_) async => <rust.Artist>[
    rust.Artist(id: BigInt.from(2116), name: '林俊杰'),
    rust.Artist(id: BigInt.from(2117), name: '陈奕迅'),
  ],
  loadSongsPage: (_, _) async =>
      rust.ArtistSongPageDto(songs: _artistSongs(), hasMore: false),
  loadAlbumsPage: (_, _, _) async =>
      rust.ArtistAlbumPageDto(albums: _artistAlbums(), hasMore: false),
  // MV 探测给空页 = 不生成「MV」tab(有 MV 的排版另有用例覆盖)
  loadMvsPage: (_, _) async =>
      const rust.ArtistMvPageDto(mvs: <rust.ArtistMvDto>[], hasMore: false),
  // 有绑定账号 + 2 条动态 ⇒ 生成「动态」tab(内容要切 tab 才看到)
  loadDynamics: (_) async => <rust.FeedEventDto>[
    _feedEvent(901, '周杰伦', userId: 6452, text: '新专辑预告'),
    _feedEvent(902, '周杰伦', userId: 6452, text: '巡演日程公布'),
  ],
  toggleFollow: (_, _) async => true,
);

/// 艺人页头部: 32 张专辑 / 379 首歌 / 1922.7 万粉丝, 有别名、有简介。
rust.ArtistDetailDto _artistDetail() => rust.ArtistDetailDto(
  id: BigInt.from(6452),
  name: '周杰伦',
  avatarUrl: null,
  coverUrl: null,
  alias: const <String>['Jay Chou'],
  briefDesc: '华语流行歌手、词曲创作人。',
  albumCount: BigInt.from(32),
  musicCount: BigInt.from(379),
  fansCount: BigInt.from(19227000),
  followed: false,
  userId: BigInt.from(6452),
  eventCount: BigInt.from(2),
  songs: _artistSongs().take(3).toList(),
  albums: _artistAlbums(),
);

List<rust.SongDto> _artistSongs() => <rust.SongDto>[
  for (var i = 1; i <= 6; i++) _song(600 + i, '艺人歌曲$i', artist: '周杰伦'),
];

List<rust.AlbumBrief> _artistAlbums() => <rust.AlbumBrief>[
  rust.AlbumBrief(
    id: BigInt.from(701),
    name: '范特西',
    coverUrl: null,
    trackCount: BigInt.from(10),
    publishTime: BigInt.zero,
  ),
  rust.AlbumBrief(
    id: BigInt.from(702),
    name: '叶惠美',
    coverUrl: null,
    trackCount: BigInt.from(11),
    publishTime: BigInt.zero,
  ),
];

/// 基准图: feed_360x800.png / feed_300x640_s125.png。
///
/// 应有什么: 顶部分类条(全部 / 周杰伦 / 云音乐编辑部 / 林俊杰 / 进入全部) + 3 张卡片
/// (昵称 + 2023-11-15 + 正文 + 点赞·评论·转发三个数字 + 「查看详情」, 中间那张带单曲卡),
/// 卡片头像是占位(无网络)。
///
/// 坏在哪: 分类条竖溢/被压扁、卡片正文被截断、封占位尺寸跳动, 是这一页最典型的回归;
/// 出现"3 分钟前"这类相对时间说明用例的固定时间戳被改坏了(基准图会天天变)。
Widget _feedPage() => Scaffold(
  appBar: AppBar(title: const Text('动态')),
  body: FeedView(
    loggedIn: true,
    onLogin: () {},

    onOpenUrl: (_) async {},
    loadFeed: () async => <rust.FeedEventDto>[
      _feedEvent(
        11,
        '周杰伦',
        userId: 6452,
        text: '新专辑终于录完了, 谢谢大家等这么久。',
        likedCount: 1200,
        commentCount: 86,
        shareCount: 42,
      ),
      _feedEvent(
        12,
        '云音乐编辑部',
        userId: 30,
        text: '本周华语新歌速递',
        song: _song(601, '华语热歌1', artist: '周杰伦'),
        likedCount: 320,
        commentCount: 12,
        shareCount: 8,
      ),
      _feedEvent(13, '林俊杰', userId: 2116, text: '练团结束, 下一站见。', likedCount: 96),
    ],
    loadSubscribedArtists: () async => <rust.Artist>[
      rust.Artist(id: BigInt.from(6452), name: '周杰伦'),
      rust.Artist(id: BigInt.from(2116), name: '林俊杰'),
    ],
  ),
);

/// 一条动态: 时间戳固定成 unix 1700000000000(2023-11-15), 比"今天"早 30 天以上,
/// 于是页面退化成日期文案 —— 否则"3 分钟前/N 天前"会随运行时刻漂移, 基准图天天变。
rust.FeedEventDto _feedEvent(
  int id,
  String userName, {
  int userId = 10,
  String text = '正文',
  rust.SongDto? song,
  int likedCount = 0,
  int commentCount = 0,
  int shareCount = 0,
}) => rust.FeedEventDto(
  id: BigInt.from(id),
  threadId: 'A_EV_2_${id}_$userId',
  userId: BigInt.from(userId),
  kind: song == null ? 'text' : 'song',
  userName: userName,
  avatarUrl: null,
  text: text,
  song: song,
  coverUrl: null,
  images: const <String>[],
  videoUrl: null,
  title: '',
  timeMs: BigInt.from(1700000000000),
  liked: false,
  likedCount: BigInt.from(likedCount),
  shareCount: BigInt.from(shareCount),
  commentCount: BigInt.from(commentCount),
);

final List<_GoldenPage> _goldenPages = <_GoldenPage>[
  _GoldenPage('settings', _settingsPage),
  _GoldenPage('account', _accountPage),
  _GoldenPage('recommend', _recommendPage),
  _GoldenPage('mine', _minePage),
  _GoldenPage('search_landing', _searchLandingPage),
  _GoldenPage('messages', _messagesPage),
  // churn top-10 里最易回归的三页(审计建议 11), 详见各自 builder 上方的注释
  _GoldenPage('playlist_detail', _playlistDetailPage, frames: 24),
  _GoldenPage('artist', _artistPage),
  _GoldenPage('feed', _feedPage),
];

/// 本机是否装了可用于 golden 的 CJK 字体(`.ttc`/`.otf` 存在即算)。
/// 没装就整组 skip: 用方块字生成的"基准"没有意义, 也不该在别人的机器上红。
final bool _cjkAvailable = _cjkFontCandidates.any(
  (path) => File(path).existsSync(),
);

void main() {
  // CI 上缺字体时下面 12 例会"全部 skip", 流水线看着绿其实一张图都没校验。
  // 所以 CI 里显式断言字体在: 装字体那步若装到了别的路径/装失败, 这里直接红。
  test('CI 必须能拿到 CJK 字体(golden 不允许静默整组跳过)', () {
    if (Platform.environment['CI'] != 'true') return;
    expect(
      _cjkAvailable,
      isTrue,
      reason:
          'CI 上探测不到系统 CJK 字体(候选见 _cjkFontCandidates), '
          '18 张 golden 会被整组 skip; 检查 workflow 里的 fonts-noto-cjk 安装',
    );
  });

  setUpAll(() async {
    // 允许极小的像素差: 同一 Flutter 版本下, CI runner 与本地机器的 **CJK 字体文件
    // 版本/回退链** 不同, 少数页面会有 ~0.03% 的抗锯齿差异(实测 messages/feed
    // 84px/28.8万像素)。0.2% 容差能吸收这类字体光栅化噪声, 又远小于真实布局回归
    // (挪一个按钮就是 >1%)。
    goldenFileComparator = _TolerantGoldenFileComparator(
      Uri.parse('test/golden_pages_test.dart'),
      precisionTolerance: 0.002,
    );
    // 歌单详情只有命令式入口且数据直连 FFI, 用 FRB 自带的 mock 通道垫数据(见
    // _GoldenRustApi)。只影响下面覆盖到的那 5 个方法, 其余照旧抛。
    RustLib.initMock(api: _GoldenRustApi());
    final path = await _loadGoldenFont();
    if (path == null) {
      debugPrint(
        'golden: 未探测到系统 CJK 字体, 本次基准图里的中文会是方块(退化渲染)。'
        '装上 fonts-noto-cjk 或文泉驿后执行 --update-goldens 重出基准。',
      );
    } else {
      debugPrint('golden: 使用 CJK 字体 $path');
    }
  });

  for (final page in _goldenPages) {
    testWidgets(
      '${page.name}: 360x800 @1.0',
      // 本机没有 CJK 字体就跳过(方块字生成的基准没有意义)
      skip: !_cjkAvailable,
      (tester) async {
        await _pumpPage(
          tester,
          page.build(),
          size: const Size(360, 800),
          frames: page.frames,
        );
        await _expectGolden(tester, '${page.name}_360x800');
      },
    );

    testWidgets(
      '${page.name}: 300x640 @1.25 字号',
      // 本机没有 CJK 字体就跳过(方块字生成的基准没有意义)
      skip: !_cjkAvailable,
      (tester) async {
        await _pumpPage(
          tester,
          page.build(),
          size: const Size(300, 640),
          textScale: 1.25,
          frames: page.frames,
        );
        await _expectGolden(tester, '${page.name}_300x640_s125');
      },
    );
  }

  // 宽档双列(2026-11-18 方案 A · S1): 1280x720 = 桌面默认窗口, 唯一会走
  // 「页内双列」分支的视口。必须带 ContentWidthLimit(真实壳层的 840 限宽),
  // 否则页面按整窗排版, 右栏 968 而不是 528。
  //
  // 应有什么: 左侧 300 宽一列只有歌单信息(封面 120 / 标题 / 创建者 / 「12 首 ·
  // 播放 128000 次」/ 华语·流行 标签 / 简介), 右侧 528 宽一列是筛选条 + 曲目行
  // (第 1 行正在播放高亮, 其余「序号 歌名 / 艺人 · 专辑 / 04:29 + 红心」);
  // AppBar 仍通栏 840(不跟左栏缩), 两侧是壳层的 220 留白。
  //
  // 坏在哪: 两栏宽度/间距偏 1dp 以上、左栏混进曲目、只剩一列、整屏错误态。
  // 以后动 kContentMaxWidth / kTwoColumnListWidth / kTwoColumnGap 都要重出这一张:
  //   flutter test test/golden_pages_test.dart --update-goldens --plain-name 'playlist_detail: 1280x720'
  testWidgets('playlist_detail: 1280x720(双列)', skip: !_cjkAvailable, (
    tester,
  ) async {
    await _pumpPage(
      tester,
      _playlistDetailPage(),
      size: const Size(1280, 720),
      frames: 24,
      contentLimit: true,
    );
    await _expectGolden(tester, 'playlist_detail_1280x720');
  });

  // 宽档双列(2026-11-18 方案 A · S2): 播客详情页与歌单详情同一套双列骨架。
  //   flutter test test/golden_pages_test.dart --update-goldens --plain-name 'podcast_detail: 1280x720'
  testWidgets('podcast_detail: 1280x720(双列)', skip: !_cjkAvailable, (
    tester,
  ) async {
    await _pumpPage(
      tester,
      _podcastDetailPage(),
      size: const Size(1280, 720),
      frames: 24,
      contentLimit: true,
    );
    await _expectGolden(tester, 'podcast_detail_1280x720');
  });

  // 主从分栏(方案 B · S4): 840 内容区里 左 408 / 间距 12 / 右 420。
  //
  // 应有什么: 左栏是**搜索结果的歌单网格**(6 张卡片, 第一张「华语流行精选」带 2dp
  // primary 选中外框 —— 它就是右栏正在看的那一条), 右栏是歌单详情的**内嵌形态**
  // (没有 AppBar 与返回箭头, 顶部只有 收藏/分享 图标行, 下面照旧是头部卡片 + 筛选条 +
  // 曲目行); 右栏有圆角细边框, 与左栏在视觉上分开。
  //
  // 坏在哪: 左栏消失/整宽、右栏偏 1dp 以上、右栏里出现 AppBar 或返回箭头、选中外框丢、
  // 右栏详情变错误态。以后动 kDetailPaneWidth / kTwoColumnGap 都要重出这一张:
  //   flutter test test/golden_pages_test.dart --update-goldens --plain-name 'master_detail: 1280x720'
  testWidgets('master_detail: 1280x720(主从分栏)', skip: !_cjkAvailable, (
    tester,
  ) async {
    await _pumpPage(
      tester,
      const _MasterDetailGoldenHost(),
      size: const Size(1280, 720),
      frames: 24,
      contentLimit: true,
    );
    await _expectGolden(tester, 'master_detail_1280x720');
  });
}

/// 带极小容差的 golden 比较器(官方 LocalFileComparator 文档里的推荐写法)。
///
/// 为什么需要: 基准图在本地生成、CI 上校验。同一 Flutter 版本下引擎一致, 但 CJK
/// 字体文件来源不同(Ubuntu fonts-noto-cjk vs 本地发行版字体), 个别页面的字形
/// 抗锯齿会出现 <0.1% 的差异 —— 这种差异不是回归, 却会让门禁常年假红。
/// 真实布局回归(多一行 / 挪一个按钮 / 字号变化)的差异远大于 0.2%。
class _TolerantGoldenFileComparator extends LocalFileComparator {
  _TolerantGoldenFileComparator(
    super.testFile, {
    required double precisionTolerance,
  }) : assert(
         precisionTolerance >= 0 && precisionTolerance <= 1,
         'precisionTolerance must be between 0 and 1',
       ),
       _precisionTolerance = precisionTolerance;

  final double _precisionTolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    final passed = result.passed || result.diffPercent <= _precisionTolerance;
    if (passed) {
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
