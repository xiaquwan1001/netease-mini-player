// Golden(视觉回归)基准: 6 个高价值页面的整屏排版快照。
//
// 为什么需要: 现有 widget 测试只断言"某段文本存在/不溢出", 改动 A 页面把 B 的
// 间距、换行、留白挤坏时全都测不出来。这里把整屏像素锁成基准图, 布局回归直接变红。
//
// 运行前提(重要):
//   * cwd 必须是 `ui/`(`matchesGoldenFile` 的路径按测试文件目录解析, 字体探测
//     也依赖本机绝对路径);
//   * golden 只在本机 Linux 生成与校验 —— 字体文件、Skia 版本、抗锯齿在不同平台/
//     不同 Flutter 版本间都有差异, 换机或升级 Flutter 后需 `--update-goldens` 重出
//     基准, 否则会大面积假失败。**CI 暂不接入**(接入前得先把渲染环境容器化)。
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
// 门禁口径: 标 @Tags(['golden']), CI 用 `--exclude-tags 'network || golden'` 跳过
// (GitHub runner 没有 fonts-noto-cjk, 渲染差异会假失败); 本机没有 CJK 字体时用例
// 自动 skip 并给出安装提示, 不会红。
@Tags(['golden'])
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/messages_page.dart';
import 'package:minincm/src/mine_view.dart';
import 'package:minincm/src/recommend_view.dart';
import 'package:minincm/src/rust/api.dart' as rust;
import 'package:minincm/src/search_landing.dart';
import 'package:minincm/src/settings_account_page.dart';
import 'package:minincm/src/settings_view.dart';
import 'package:minincm/src/theme.dart';

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
        home: Builder(
          builder: (context) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              // 字号走 MediaQuery 而不是 platformDispatcher.textScaleFactorTestValue,
              // 与 narrow_width_audit_test 的 pumpNarrow 保持同一口径
              data: textScale == 1.0
                  ? media
                  : media.copyWith(textScaler: TextScaler.linear(textScale)),
              child: page,
            );
          },
        ),
      ),
    ),
  );
  await _pumpFrames(tester);
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
rust.SongDto _song(int id, String name, {String artist = '艺人'}) => rust.SongDto(
  id: BigInt.from(id),
  name: name,
  artist: artist,
  artistId: BigInt.one,
  album: '专辑名',
  albumId: BigInt.one,
  coverUrl: null,
  durationMs: BigInt.from(269000),
  fee: 0,
  vip: false,
  paid: false,
  playable: true,
);

rust.Playlist _playlist(int id, String name) => rust.Playlist(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  trackCount: BigInt.from(12),
  special: false,
  subscribed: false,
);

rust.PodcastRadio _radio(int id, String name) => rust.PodcastRadio(
  id: BigInt.from(id),
  name: name,
  coverUrl: null,
  description: '',
  djName: '主播名',
  programCount: BigInt.from(8),
  playCount: BigInt.zero,
);

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

// ---------------------------------------------------------------- 被测页面

/// 一个 golden 目标: 名字进文件名, build 每次调用都产出全新的 widget(避免状态串味).
class _GoldenPage {
  const _GoldenPage(this.name, this.build);

  final String name;
  final Widget Function() build;
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
    onPlaySongs: (_, _) {},
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
    onPlaySongs: (_, _) {},
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
    recommended: '周杰伦',
    onSelected: (_) {},
    onClearHistory: () {},
  ),
);

/// 第 6 个页面用「消息中心」而不是歌单详情页: 歌单详情页(`_PlaylistDetailPage`)
/// 是私有类, 对外只有 `openPlaylistDetail(...)` 这种命令式入口, 注入点(曲目
/// 分页/评论/收藏/作者)太多且必须挂在路由上, 拿来做整屏基准既脆又难定位。
/// 消息页的 loader 全部可注入, 页签 + 列表 + 未读角标三种排版都在一屏内, 更适合
/// 当"改 A 破坏 B"的探针。
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

final List<_GoldenPage> _goldenPages = <_GoldenPage>[
  _GoldenPage('settings', _settingsPage),
  _GoldenPage('account', _accountPage),
  _GoldenPage('recommend', _recommendPage),
  _GoldenPage('mine', _minePage),
  _GoldenPage('search_landing', _searchLandingPage),
  _GoldenPage('messages', _messagesPage),
];

/// 本机是否装了可用于 golden 的 CJK 字体(`.ttc`/`.otf` 存在即算)。
/// 没装就整组 skip: 用方块字生成的"基准"没有意义, 也不该在别人的机器上红。
final bool _cjkAvailable = _cjkFontCandidates.any(
  (path) => File(path).existsSync(),
);

void main() {
  setUpAll(() async {
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
        await _pumpPage(tester, page.build(), size: const Size(360, 800));
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
        );
        await _expectGolden(tester, '${page.name}_300x640_s125');
      },
    );
  }
}
