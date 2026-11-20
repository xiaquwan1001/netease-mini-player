// T5: AccountActions 直测(审计 7.5)。
//
// 拆壳 S7 之后"登录态动作 / 红心集合 / 切号与失效 / 歌单浏览态四件套"全在这个
// 类里, 但此前只有 home_page 的间接覆盖。这里直接构造它 + RustLib 替身,
// 把两条主链(切号 → 重取红心; 登录态失效 → 清红心)与关键错误分支钉住:
//
// - 切号成功: 账号簿切换 → refreshInfo → 重取红心 → 清上一个账号的日推缓存
// - 切号到同一账号: 不清缓存(避免白拉一次网络)
// - 切号失败/抛错: 文案与返回值
// - syncAccount 的 auth 错误才踢下线, 网络抖动不动登录态
// - 登出: 清红心 + 清上一个账号的日推缓存
// - refreshInfo/loadLiked 的失败静默
// - 歌单浏览态写入口的单写语义(含 exitHeartMode 的幂等)
// - 未登录时的列表/红心详情入口
//
// RustLib.initMock 每个进程只能调一次, 替身是全局单实例 + 每个用例 reset。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart'
    show Uint64List;
import 'package:flutter_test/flutter_test.dart';
import 'package:minincm/src/app_settings.dart';
import 'package:minincm/src/auth.dart';
import 'package:minincm/src/home/account_actions.dart';
import 'package:minincm/src/rust/api_all.dart' as rust;
import 'package:minincm/src/rust/frb_generated.dart';
import 'package:minincm/src/song_actions.dart' show SongActionSource;

import 'support/fakes.dart';

/// Rust 侧替身: 只实现被测代码真的会调的入参。
class _FakeApi implements RustLibApi {
  _FakeApi._();

  /// 进程内唯一替身(RustLib.initMock 每个进程只能调一次)。
  static final _FakeApi instance = _FakeApi._();

  /// 当前会话 uid(`DailyPlaylistCache.resolveAccountKey` 的第 1 信源)。
  BigInt currentUid = BigInt.one;

  bool initLoggedIn = true;
  Object? initError;

  List<BigInt> likedIds = <BigInt>[BigInt.one, BigInt.two];
  Object? likedError;

  /// accountSwitch 的返回值 / 抛错; 成功时顺手把会话 uid 改过去(真实 Rust 行为)。
  bool switchResult = true;
  Object? switchError;

  Object? syncActiveError;
  rust.AccountDto syncActiveResult = rust.AccountDto(
    userId: BigInt.one,
    nickname: '当前账号',
    active: true,
    vip: false,
  );

  final List<BigInt> switchCalls = <BigInt>[];
  final List<String?> initDataDirs = <String?>[];
  int logoutCalls = 0;
  int likedCalls = 0;
  int myPlaylistsCalls = 0;
  List<rust.Playlist> myPlaylists = <rust.Playlist>[];

  void reset() {
    currentUid = BigInt.one;
    initLoggedIn = true;
    initError = null;
    likedIds = <BigInt>[BigInt.one, BigInt.two];
    likedError = null;
    switchResult = true;
    switchError = null;
    syncActiveError = null;
    switchCalls.clear();
    initDataDirs.clear();
    logoutCalls = 0;
    likedCalls = 0;
    myPlaylistsCalls = 0;
    myPlaylists = <rust.Playlist>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');

  @override
  Future<rust.InitInfo> crateApiInit({String? dataDir}) async {
    initDataDirs.add(dataDir);
    final err = initError;
    if (err != null) throw err;
    return rust.InitInfo(
      dataDir: dataDir ?? '',
      deviceId: 'device',
      loggedIn: initLoggedIn,
      vip: false,
      providers: const <rust.ProviderInfo>[],
    );
  }

  @override
  Future<Uint64List> crateApiLibraryLikedIds() async {
    likedCalls += 1;
    final err = likedError;
    if (err != null) throw err;
    return Uint64List.fromList(likedIds.map((e) => e.toInt()).toList());
  }

  @override
  Future<bool> crateApiAccountAccountSwitch({required BigInt userId}) async {
    switchCalls.add(userId);
    final err = switchError;
    if (err != null) throw err;
    if (switchResult) currentUid = userId;
    return switchResult;
  }

  @override
  Future<rust.AccountDto> crateApiAccountAccountSyncActive() async {
    final err = syncActiveError;
    if (err != null) throw err;
    return syncActiveResult;
  }

  @override
  Future<bool> crateApiAccountLogout() async {
    logoutCalls += 1;
    return true;
  }

  @override
  Future<BigInt> crateApiSocialMyUid() async => currentUid;

  @override
  Future<List<rust.AccountDto>> crateApiAccountAccounts() async => const [];

  @override
  Future<bool> crateApiAccountAccountRemove({required BigInt userId}) async => true;

  @override
  Future<List<rust.CredentialOpDto>> crateApiAccountCredentialPendingWrites() async =>
      const <rust.CredentialOpDto>[];

  @override
  Future<List<rust.Playlist>> crateApiLibraryMyPlaylists() async {
    myPlaylistsCalls += 1;
    return myPlaylists;
  }

  @override
  Future<List<rust.Playlist>> crateApiRecommendDailyRecommendPlaylists() async =>
      const <rust.Playlist>[];
}

/// 登录门面替身(桌面分支, 不碰 WebView/通道)。
class _FakeAuth extends Auth {
  int logoutCalls = 0;

  @override
  bool get isAndroid => false;

  @override
  Future<bool> logout() async {
    logoutCalls += 1;
    return true;
  }

  @override
  Future<String?> loginWeb() async => null;

  @override
  Future<bool> commitCookie(String cookie) async => true;
}

/// 模拟 HomePage 的接线: 页面态(登录态快照 / 红心集合)仍在"页面"这一侧。
class _Harness {
  _Harness({this.dataDir});

  final _FakeApi api = _FakeApi.instance;
  final _FakeAuth auth = _FakeAuth();

  /// null = dataDir 未知(启动早期), 缓存入口应原样透传。
  final String? dataDir;

  rust.InitInfo? info;
  Set<BigInt> liked = <BigInt>{};

  final List<String> toasts = <String>[];
  final List<String> errors = <String>[];
  final List<bool> searchBusy = <bool>[];
  final List<(String, BigInt)> interactions = <(String, BigInt)>[];

  int setInfoCalls = 0;
  int setLikedCalls = 0;
  int clearLikedCalls = 0;
  int rebuildCalls = 0;
  int notifies = 0;

  late final AccountActions actions = AccountActions(
    contextOf: () => contextOf(),
    isMounted: () => true,
    auth: auth,
    infoOf: () => info,
    setInfo: (v) {
      setInfoCalls += 1;
      info = v;
    },
    dataDirOf: () async => dataDir,
    toast: toasts.add,
    toastError: errors.add,
    likedOf: () => liked,
    markLiked: (trackId, isLiked) {
      isLiked ? liked.add(trackId) : liked.remove(trackId);
    },
    setLiked: (ids) {
      setLikedCalls += 1;
      liked = ids;
    },
    clearLiked: () {
      clearLikedCalls += 1;
      liked = <BigInt>{};
    },
    rebuildActionsHost: () => rebuildCalls += 1,
    setSearchBusy: searchBusy.add,
    currentTrackIdOf: () => null,
    touchInteraction: (kind, id) => interactions.add((kind, id)),
  )..addListener(() => notifies += 1);

  /// 用例里只有"真的会导航"的路径才允许取 BuildContext;
  /// 取到就说明被测方法没在未登录/找不到的早退分支上停住。
  BuildContext contextOf() =>
      throw StateError('这条路径不该用 BuildContext(说明早退分支没生效)');

  void dispose() => actions.dispose();
}

void main() {
  final api = _FakeApi.instance;
  RustLib.initMock(api: api);

  late _Harness h;
  late Directory dir;

  /// 页面侧的登录态快照(账号动作里的 dataDir 就从这里读)。
  rust.InitInfo infoOf(String dataDir, {bool loggedIn = true}) => rust.InitInfo(
    dataDir: dataDir,
    deviceId: 'device',
    loggedIn: loggedIn,
    vip: false,
    providers: const <rust.ProviderInfo>[],
  );

  final settings = AppSettings.instance;
  late int dailyCacheDays;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ncm-account');
    h = _Harness(dataDir: dir.path);
    api.reset();
    dailyCacheDays = settings.dailyCacheDays;
  });

  tearDown(() async {
    settings.dailyCacheDays = dailyCacheDays;
    settings.notifyListeners();
    h.dispose();
    await dir.delete(recursive: true);
  });

  group('切号 → 重取红心', () {
    test('切到另一个账号: 切号 + 刷新登录态 + 重取红心 + 清上一个账号的日推缓存', () async {
      // 上一个账号(uid-1)的日推缓存痕迹
      final stale = Directory('${dir.path}/cache/daily-playlists/uid-1');
      await stale.create(recursive: true);
      await File('${stale.path}/2026-01-01.json').writeAsString('[]');

      api.likedIds = <BigInt>[BigInt.from(11), BigInt.from(22)];
      h.info = infoOf(dir.path);

      final ok = await h.actions.switchAccount(
        rust.AccountDto(
          userId: BigInt.two,
          nickname: '新号',
          active: false,
          vip: false,
        ),
      );
      await pumpEventQueue();

      expect(ok, isTrue);
      expect(api.switchCalls, [BigInt.two]);
      expect(h.setInfoCalls, 1, reason: '切号后必须刷新 init 信息');
      expect(h.info!.loggedIn, isTrue);
      expect(h.liked, {
        BigInt.from(11),
        BigInt.from(22),
      }, reason: '红心集合要按新账号重取');
      expect(h.rebuildCalls, 1, reason: '"..."菜单宿主按新登录态重建');
      expect(h.toasts.single, '已切换到 新号');
      expect(h.errors, isEmpty);
      expect(await stale.exists(), isFalse, reason: '换人用同一台机器不该翻得到别人的日推清单');
    });

    test('切到同一个账号: 不清日推缓存(避免白拉一次网络)', () async {
      final keep = Directory('${dir.path}/cache/daily-playlists/uid-1');
      await keep.create(recursive: true);
      h.info = infoOf(dir.path);

      final ok = await h.actions.switchAccount(
        rust.AccountDto(
          userId: BigInt.one,
          nickname: '当前账号',
          active: true,
          vip: false,
        ),
      );
      await pumpEventQueue();

      expect(ok, isTrue);
      expect(await keep.exists(), isTrue);
      expect(h.toasts.single, '已切换到 当前账号');
    });

    test('账号簿里没有凭据(switch 返回 false): 提示重新登录, 登录态不变', () async {
      api.switchResult = false;

      final ok = await h.actions.switchAccount(
        rust.AccountDto(
          userId: BigInt.from(9),
          nickname: '', // 没昵称时用 uid 兜底文案
          active: false,
          vip: false,
        ),
      );
      await pumpEventQueue();

      expect(ok, isFalse);
      expect(h.toasts.single, '这个账号没存过凭据, 请重新登录');
      expect(h.setInfoCalls, 1, reason: '切换失败也要刷新一次(确认当前登录态)');
    });

    test('切号抛错: 转成友好文案, 不刷新登录态', () async {
      api.switchError = rust.FfiError(
        kind: 'network',
        retryable: false,
        detail: 'connection reset',
      );

      final ok = await h.actions.switchAccount(
        rust.AccountDto(
          userId: BigInt.two,
          nickname: '新号',
          active: false,
          vip: false,
        ),
      );

      expect(ok, isFalse);
      expect(h.errors.single, startsWith('切换账号失败: '));
      expect(h.errors.single, contains('网络不稳定'));
      expect(h.setInfoCalls, 0, reason: '切号没成不该动登录态快照');
      expect(h.clearLikedCalls, 0);
    });
  });

  group('登录态校验(失效态)', () {
    test('服务端明确回 auth 错: 清登录态 + 清红心 + 提示重新登录', () async {
      api.syncActiveError = rust.FfiError(
        kind: 'auth',
        retryable: false,
        detail: 'token expired',
      );
      api.initLoggedIn = false;
      h.liked = <BigInt>{BigInt.one};
      h.info = infoOf(dir.path);

      await h.actions.syncAccount();
      await pumpEventQueue();

      expect(api.logoutCalls, 1, reason: 'auth 错才真的退出');
      expect(h.setInfoCalls, 1);
      expect(h.info!.loggedIn, isFalse);
      expect(h.clearLikedCalls, 1, reason: '未登录不再显示任何红心');
      expect(h.liked, isEmpty);
      expect(h.toasts.single, '登录状态已失效, 请重新登录');
    });

    test('网络/风控失败不动登录态(一次抖动不把人踢下线)', () async {
      api.syncActiveError = rust.FfiError(
        kind: 'network',
        retryable: true,
        detail: 'os error 104',
      );

      await h.actions.syncAccount();
      await pumpEventQueue();

      expect(api.logoutCalls, 0);
      expect(h.setInfoCalls, 0);
      expect(h.clearLikedCalls, 0);
      expect(h.toasts, isEmpty);
      expect(h.errors, isEmpty);
    });

    test('校验成功: 什么都不改(只留待命)', () async {
      await h.actions.syncAccount();
      expect(api.logoutCalls, 0);
      expect(h.setInfoCalls, 0);
      expect(h.toasts, isEmpty);
    });
  });

  group('登出 / 红心拉取', () {
    test('登出: 清上一个账号的日推缓存 + 刷新登录态 + 清红心', () async {
      final stale = Directory('${dir.path}/cache/daily-playlists/uid-1');
      await stale.create(recursive: true);
      api.initLoggedIn = false;
      h.liked = <BigInt>{BigInt.one};
      h.info = infoOf(dir.path);

      await h.actions.logout();
      await pumpEventQueue();

      expect(h.auth.logoutCalls, 1, reason: '清 WebView/凭据走登录门面');
      expect(h.clearLikedCalls, 1);
      expect(h.toasts.single, '已退出登录(账号仍留在账号簿)');
      expect(await stale.exists(), isFalse);
    });

    test('未登录时登出: 匿名分区不删(没有别人的数据要清)', () async {
      final anon = Directory('${dir.path}/cache/daily-playlists/anonymous');
      await anon.create(recursive: true);
      api.currentUid = BigInt.zero;
      h.info = infoOf(dir.path);

      await h.actions.logout();
      await pumpEventQueue();

      expect(await anon.exists(), isTrue);
    });

    test('拉红心失败静默: 不覆盖已有集合, 不弹错', () async {
      h.liked = <BigInt>{BigInt.from(5)};
      api.likedError = rust.FfiError(
        kind: 'internal',
        retryable: false,
        detail: 'boom',
      );

      await h.actions.loadLiked();

      expect(h.setLikedCalls, 0);
      expect(h.liked, {BigInt.from(5)}, reason: '失败不能把红心清空');
      expect(h.errors, isEmpty);
    });

    test('refreshInfo 失败保持旧状态(启动早期 FFI 未就绪)', () async {
      api.initError = StateError('rust not ready');

      await h.actions.refreshInfo();

      expect(h.setInfoCalls, 0);
      expect(h.rebuildCalls, 0);
      expect(h.toasts, isEmpty);
      expect(h.errors, isEmpty);
    });
  });

  group('歌单浏览态(列表态)写入口', () {
    test('起播/恢复/心动模式/退出: 四件套的字段与单写语义', () {
      expect(h.actions.libraryOpen, isFalse);

      h.actions.applyPlaybackStarted(
        BigInt.from(5),
        SongActionSource.dailyRecommend,
      );
      expect(h.actions.libraryTitle, '正在播放');
      expect(h.actions.libraryPlaylistId, isNull);
      expect(h.actions.queuePlaylistId, BigInt.from(5));
      expect(h.actions.playSource, SongActionSource.dailyRecommend);
      expect(h.notifies, 1);

      h.actions.enterHeartMode();
      expect(h.actions.libraryTitle, '心动模式');
      expect(h.actions.queuePlaylistId, isNull, reason: '心动模式不是歌单队列');
      expect(h.notifies, 2);

      // 幂等: 标题已经不是心动模式时不再通知(避免无意义整页重建)
      h.actions.exitHeartMode();
      expect(h.actions.libraryTitle, '正在播放');
      expect(h.notifies, 3);
      h.actions.exitHeartMode();
      expect(h.notifies, 3, reason: '重复退出不重建');

      h.actions.leaveLibrary();
      expect(h.actions.libraryTitle, isNull);
      expect(h.actions.libraryOpen, isFalse);
      expect(h.notifies, 4);

      h.actions.applyPlaybackStarted(BigInt.from(6), SongActionSource.playlist);
      h.actions.applyPlaybackRestored();
      expect(h.actions.libraryTitle, isNull);
      expect(h.actions.queuePlaylistId, isNull);
      expect(h.notifies, 6);
    });

    test('setPlaySource / clearQueuePlaylistId 不重建界面(与拆分前一致)', () {
      h.actions.setPlaySource(SongActionSource.personalFm);
      h.actions.clearQueuePlaylistId();
      expect(h.actions.playSource, SongActionSource.personalFm);
      expect(h.actions.queuePlaylistId, isNull);
      expect(h.notifies, 0);
    });
  });

  group('未登录入口 / 我喜欢的音乐 id', () {
    test('未登录点"关注与粉丝": 只给提示, 不导航(不取 BuildContext)', () async {
      h.info = null;
      await h.actions.openUserList(startOnFans: true);
      expect(h.toasts.single, '登录后才能查看关注与粉丝');
    });

    test('未登录点"我喜欢的音乐": 只给提示, 不转圈也不导航', () async {
      h.info = null;
      await h.actions.openLikedDetail();
      expect(h.toasts.single, '登录后才能查看我喜欢的音乐');
      expect(h.searchBusy, isEmpty);
    });

    test('解析"我喜欢的音乐" id: 命中 special 后缓存, 第二次不再请求', () async {
      api.myPlaylists = <rust.Playlist>[
        fakePlaylist(id: 3, name: '普通歌单'),
        fakePlaylist(id: 9, name: '我喜欢的音乐', special: true),
      ];

      await h.actions.resolveLikedPlaylistId();
      expect(h.actions.likedPlaylistId, BigInt.from(9));
      expect(h.notifies, 1);

      await h.actions.resolveLikedPlaylistId();
      expect(api.myPlaylistsCalls, 1, reason: 'id 已缓存, 不再请求');
      expect(h.notifies, 1);
    });

    test('解析失败静默: 只是"定位正在播放"少一个依据, 不弹错', () async {
      api.myPlaylists = const <rust.Playlist>[];

      await h.actions.resolveLikedPlaylistId();
      expect(h.actions.likedPlaylistId, isNull);
      expect(h.notifies, 0);
      expect(h.errors, isEmpty);
    });
  });

  group('日推缓存入口', () {
    test('dataDir 未知时透传 rust 调用(不写任何文件)', () async {
      final noDir = _Harness();
      addTearDown(noDir.dispose);

      expect(await noDir.actions.dailyPlaylists(), isEmpty);
      expect(await noDir.actions.dailyLocalDays(), isEmpty);
    });

    test('缓存天数设为 0(关闭): 历史本地天直接返回空', () async {
      settings.dailyCacheDays = 0;
      h.info = rust.InitInfo(
        dataDir: dir.path,
        deviceId: 'device',
        loggedIn: true,
        vip: false,
        providers: const <rust.ProviderInfo>[],
      );

      expect(await h.actions.dailyLocalDays(), isEmpty);
    });
  });
}
