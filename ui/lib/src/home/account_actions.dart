import 'dart:async';

import 'package:flutter/material.dart';

import '../app_settings.dart' show AppSettings;
import '../auth.dart' show Auth;
import '../daily_cache.dart' show DailyCacheDay, DailyPlaylistCache;
import '../detail_page.dart' show showPlaylistDetail;
import '../keystore.dart' show credentialSync;
import '../login_sheet.dart' show showLoginSheet;
import '../net_retry.dart' show errorKind, friendlyError, retryNetwork;
import '../platform.dart' show PlatformBridge;
import '../rust/api.dart' as rust;
import '../settings_account_page.dart' show showAccountPage;
import '../song_actions.dart' show SongActionSource;
import '../user_list_page.dart' show showUserList;
import '../vip_page.dart' show showVipPage;

/// 账号/登录态动作 + 二级页导航(从 main.dart 的 _HomePageState 搬出,
/// 2026-11 拆壳 S7, 对应审计 G7 + G9)。
///
/// 搬的是什么(逐行等价搬运, 不改文案/不改判定/不改调用顺序):
/// - **登录态动作(原 G7)**: 登录 [login](扫码通道 + 安卓 WebView 两条路)、
///   账号页 [openAccountPage](账号簿/切换/移除/清除凭据)、切号 [switchAccount]、
///   退出 [logout](可选 thenLogin)、登录态校验 [syncAccount]、init 信息刷新
///   [refreshInfo]、红心集合拉取 [loadLiked]、会员页 [openVip]。
/// - **二级页导航(原 G9)**: 关注/粉丝 [openUserList]、歌单详情 [openPlaylist]、
///   "我喜欢的音乐"详情 [openLikedDetail] 与 id 懒解析 [resolveLikedPlaylistId]。
/// - **歌单浏览态(列表态)的写入口**: [applyPlaybackStarted] / [applyPlaybackRestored] /
///   [leaveLibrary] / [enterHeartMode] / [setPlaySource] / [clearQueuePlaylistId]。
///   字段本体(标题/歌单 id/队列来源/来源标记)搬到这里持有, 页面只读。
/// - **日推缓存按 uid 分区的入口**: [dailyPlaylists] / [dailyLocalDays] /
///   [purgeDailyCache](登出/切号时清上一个账号的缓存)。
///
/// 所有权边界(为什么这些仍留在页面):
/// - **登录态快照 `_info` / 红心集合 `_liked` 仍是页面状态**: 页面 build、
///   `_visibleSongs`、[SongActionWiring] 都直接读它们, 这里通过 [infoOf] /
///   [likedOf] 只读, 改动回灌 [setInfo] / [setLiked] / [clearLiked] / [markLiked]。
/// - **歌单浏览态的"单写"归属**: [_libraryTitle] 是搜索态/心动模式/现场恢复
///   三处共享的真相, **只在本类里被赋值**(唯一写入口就是下面那四个 apply/enter/
///   leave 方法 + [setPlaySource] / [clearQueuePlaylistId]), 页面与
///   [QueueSheetController]/[PlaybackCoordinator] 的 `libraryTitleOf` 注入都只读
///   [libraryTitle], 所以不会出现两处各自 setState 打架。
/// - **心动模式取数**(`_heartMode`)、`_playFromList`/`_playFromSearch`、播放轮询
///   仍在页面/协调器: 它们只是**调用**上面的写入口, 不直接碰字段。
/// - **需要 BuildContext 的东西**一律不进来: 登录 sheet / 账号页 / 歌单详情 /
///   关注列表 / toast 都经 [contextOf] 在调用瞬间取, 本类不持有 BuildContext
///   (与 [SongActionWiring]/[QueueSheetController] 同款)。
///
/// 状态变化(浏览态四件套 + 我喜欢的歌单 id)一律 [notifyListeners]; 页面用
/// `addListener(→setState)` 订阅, 与拆分前"每处 setState"的重建语义一一对应。
class AccountActions extends ChangeNotifier {
  AccountActions({
    required this.contextOf,
    required this.isMounted,
    required this.auth,
    required this.infoOf,
    required this.setInfo,
    required this.dataDirOf,
    required this.toast,
    required this.toastError,
    required this.likedOf,
    required this.markLiked,
    required this.setLiked,
    required this.clearLiked,
    required this.rebuildActionsHost,
    required this.setSearchBusy,
    required this.currentTrackIdOf,
    required this.touchInteraction,
  });

  /// 当前页面的 BuildContext(sheet/账号页/详情页用; 调用瞬间取, 不缓存)。
  final BuildContext Function() contextOf;

  /// 页面是否还挂在树上(原 `mounted` 判定)。
  final bool Function() isMounted;

  /// 登录态门面(网页登录/commitCookie/logout; 登录态本体在页面 `_info`)。
  final Auth auth;

  /// 当前 init 信息快照(原 `_info`; 真相在页面)。
  final rust.InitInfo? Function() infoOf;

  /// 页面侧写回 init 信息(原 `setState(() => _info = info)`)。
  final void Function(rust.InitInfo info) setInfo;

  /// 数据目录(原 `_playback.dataDir()`; 日推缓存要用)。
  final Future<String?> Function() dataDirOf;

  /// 普通提示(页面实现: mounted 判断 + `showToast`)。
  final void Function(String message) toast;

  /// 错误提示(页面实现: mounted 判断 + `showToast(isError: true)`)。
  final void Function(String message) toastError;

  /// 当前红心集合(原 `_liked`; 真相在页面)。
  final Set<BigInt> Function() likedOf;

  /// 页面侧改单曲红心(原 `setState(() => _liked.add/remove)`; 详情页回调)。
  final void Function(BigInt trackId, bool liked) markLiked;

  /// 页面侧整批替换红心集合(原 `setState(() => _liked = ids.toSet())`)。
  final void Function(Set<BigInt> ids) setLiked;

  /// 页面侧清空红心集合(原未登录时**不** setState 的裸赋值 `_liked = {}`)。
  final void Function() clearLiked;

  /// 页面侧重建"..."菜单宿主(原 `actionsHost.value = _songActions.buildHost()`)。
  final void Function() rebuildActionsHost;

  /// 搜索忙碌态(原 `_search.setBusy`; 打开"我喜欢的音乐"要转圈)。
  final void Function(bool busy) setSearchBusy;

  /// 当前曲目 id(详情页"定位正在播放"要用)。
  final BigInt? Function() currentTrackIdOf;

  /// 记录"最近一次交互"(原 `_touchInteraction`: 我的页收藏栏排序)。
  final void Function(String kind, BigInt id) touchInteraction;

  // ---------------- 列表态(歌单浏览态)的真相 ----------------

  /// 歌单浏览态标题: 非空时列表显示"正在播放/心动模式"而不是搜索结果。
  ///
  /// 唯一写入口在下面的 apply/enter/leave 方法里(见类头注释); 页面、
  /// [QueueSheetController]、[PlaybackCoordinator] 只读。
  String? get libraryTitle => _libraryTitle;
  String? _libraryTitle;

  /// 当前浏览的歌单 id(心动模式要用 playlistId; 搜索态为 null)
  BigInt? get libraryPlaylistId => _libraryPlaylistId;
  BigInt? _libraryPlaylistId;

  /// 当前播放队列的来源歌单 id(详情页"定位正在播放"用;
  /// 搜索/心动模式/推荐流等非歌单队列为 null)
  BigInt? get queuePlaylistId => _queuePlaylistId;
  BigInt? _queuePlaylistId;

  /// "我喜欢的音乐"这个歌单的 id(懒解析: 从"我的"页点播时要用它标记队列来源)
  BigInt? get likedPlaylistId => _likedPlaylistId;
  BigInt? _likedPlaylistId;

  /// 当前播放队列的来源(决定歌曲详情页"..."里能否出现"不感兴趣":
  /// 后端只接受每日推荐(dislike_recommend_song)与私人FM(fm_trash)这两个来源)。
  ///
  /// 之前这里是个粘性的 `_fmActive` 布尔: 播过一次 FM 就永远为 true, 之后从
  /// 每日推荐播的歌也走 fm_trash; 详情页的菜单来源又硬编码成 other,
  /// 所以日推歌曲在详情页里根本看不到"不感兴趣"(用户回归反馈)。
  /// 现在每次开始播放都显式记来源, 详情页菜单直接读这个字段。
  SongActionSource get playSource => _playSource;
  SongActionSource _playSource = SongActionSource.other;

  /// 是否处于"歌单浏览态"(顶栏返回键/返回策略用, 等价于 `libraryTitle != null`)
  bool get libraryOpen => _libraryTitle != null;

  // ---------------- 浏览态写入口(全部单写于此) ----------------

  /// 起播一批曲目后的列表态(原 `_onPlaybackStarted` 里的那一处 setState)。
  void applyPlaybackStarted(BigInt? playlistId, SongActionSource source) {
    _libraryTitle = '正在播放';
    _libraryPlaylistId = null;
    _queuePlaylistId = playlistId;
    _playSource = source;
    notifyListeners();
  }

  /// 启动恢复播放现场后的页面态: 不进"歌单浏览态"(与原 `_onPlaybackRestored` 同一批字段)。
  void applyPlaybackRestored() {
    _libraryTitle = null;
    _libraryPlaylistId = null;
    _queuePlaylistId = null;
    notifyListeners();
  }

  /// 退出歌单浏览态回到搜索(原 `_onLeaveLibrary` 与 `_closeLibrary` 同一动作:
  /// 搜索、返回键、顶栏返回按钮三处都走这里)。
  void leaveLibrary() {
    _libraryTitle = null;
    _libraryPlaylistId = null;
    notifyListeners();
  }

  /// 心动模式接管列表态(原 `_heartMode` 里的 setState: 只改标题与队列来源,
  /// 保留 [libraryPlaylistId] 作为下一轮的种子歌单)。
  void enterHeartMode() {
    _libraryTitle = '心动模式';
    _queuePlaylistId = null;
    notifyListeners();
  }

  /// 退出心动模式(2026-11-18): 队列还在(就是心动那批推荐), 所以标题回到
  /// 「正在播放」而不是清成 null —— null 会把页面踢回搜索态, 用户丢掉当前列表。
  ///
  /// 必须与 `queue.mode = PlayMode.repeatAll` 同时做:
  /// [QueueSheetController.heartActive] 判定的就是这个标题, 只改 mode 会让播放条
  /// 图标永远停在心动、再点只弹「列表循环」、队列也不重排(用户反馈)。
  void exitHeartMode() {
    if (_libraryTitle != '心动模式') return;
    _libraryTitle = '正在播放';
    notifyListeners();
  }

  /// 记队列来源(原 `_playSource = ...`; 不重建界面, 与拆分前一致)。
  void setPlaySource(SongActionSource source) {
    _playSource = source;
  }

  /// 清队列来源歌单(原 `_queuePlaylistId = null`; 不重建界面, 与拆分前一致)。
  void clearQueuePlaylistId() {
    _queuePlaylistId = null;
  }

  // ---------------- 登录 / 账号 ----------------

  /// 黑胶会员(只读)页面; 未登录时页面内给「登录」入口。
  /// 入口:「我的」页的「黑胶会员」行 / 账号与会员页的「会员」分组(审查 P1-7.9)。
  Future<void> openVip() => showVipPage(contextOf(), onLogin: login);

  Future<void> login() async {
    // 桌面端: 官方网页登录的**扫码通道**(纯 Rust, 不依赖 WebView/系统 cookie).
    // 之前桌面端只能 ncm login-cookie, 等于把登录这一步踢给命令行, 体验断档.
    if (!auth.isAndroid) {
      await showLoginSheet(
        contextOf(),
        onLoggedIn: () async {
          await syncAccount();
          await refreshInfo();
        },
        openWebLogin: () =>
            PlatformBridge.openUrl('https://music.163.com/#/login'),
      );
      return;
    }
    try {
      final cookie = await auth.loginWeb();
      if (cookie == null) {
        if (!isMounted()) return;
        toastError('未获取到登录态');
        return;
      }
      final ok = await auth.commitCookie(cookie);
      if (ok) {
        // 记住这个账号(昵称/uid) 并设为当前账号, 下次可直接切换
        await syncAccount();
      }
      await refreshInfo();
      if (!isMounted()) return;
      toast(ok ? '登录成功, 账号已记住' : 'cookie 里没有 MUSIC_U, 登录未生效');
    } catch (e) {
      if (!isMounted()) return;
      toastError('登录失败: ${friendlyError(e)}');
    }
  }

  /// 账号管理页 —— 全 App 唯一账号面(账号簿/切换/添加/退出登录/清除凭据).
  /// 入口: 设置 → 账号管理 + 「我的」页资料头(资料本身可点进账号页)。
  Future<void> openAccountPage() {
    return showAccountPage(
      contextOf(),
      info: infoOf(),
      isAndroid: auth.isAndroid,
      onLogin: login,
      onLogout: () => logout(),
      onSwitchAccount: switchAccount,
      onRemoveAccount: (account) async {
        await rust.accountRemove(userId: account.userId);
        await refreshInfo();
        if (!isMounted()) return;
        toast('已从账号簿移除');
      },
      // 隐私: 退出登录 + 删掉本机所有账号凭据(设备指纹保留).
      onPurgeLocal: () async {
        await auth.logout();
        for (final account in await rust.accounts()) {
          await rust.accountRemove(userId: account.userId);
        }
        // 隐私动作一并清掉日推缓存(所有账号 + 匿名), 不留推荐痕迹。
        final dir = infoOf()?.dataDir;
        if (dir != null && dir.isNotEmpty) {
          await DailyPlaylistCache.purgeAll(dataDir: dir);
        }
        await refreshInfo();
        if (!isMounted()) return;
        toast('已清除本机登录凭据');
      },
    );
  }

  /// 切换/重新登录账号(未登录时点账号簿里的一行也走这里).
  /// 返回是否真的切成功, 账号页据此把登录态翻成"已登录"。
  Future<bool> switchAccount(rust.AccountDto account) async {
    final name = account.nickname.isEmpty
        ? account.userId.toString()
        : account.nickname;
    try {
      // 切号前先记下**上一个账号**的缓存键: accountSwitch 之后就变成新账号了。
      final previousKey = await DailyPlaylistCache.resolveAccountKey();
      final ok = await rust.accountSwitch(userId: account.userId);
      // 切到同一个账号(重复点同一行)就不用清, 清了只是白拉一次网络。
      if (ok &&
          previousKey != DailyPlaylistCache.accountKeyFor(account.userId)) {
        unawaited(purgeDailyCache(previousKey));
      }
      await refreshInfo();
      if (!isMounted()) return ok;
      toast(ok ? '已切换到 $name' : '这个账号没存过凭据, 请重新登录');
      return ok;
    } catch (e) {
      if (!isMounted()) return false;
      toastError('切换账号失败: ${friendlyError(e)}');
      return false;
    }
  }

  /// refresh init 信息(登录态/设备 id/会员状态)
  Future<void> refreshInfo() async {
    try {
      final dir = await dataDirOf();
      final info = await rust.init(dataDir: dir);
      if (isMounted()) setInfo(info);
      // 登录/登出/切号都汇到 refreshInfo, 在这里统一 drain Keystore 桥的 pending
      unawaited(credentialSync.drainPending());
      rebuildActionsHost();
      if (info.loggedIn) {
        await loadLiked();
      } else {
        clearLiked();
      }
    } catch (_) {
      // init 失败保持旧状态
    }
  }

  /// 记账号资料(昵称/uid/会员)进账号簿; 离线拉不到只是没名字, 不影响登录态.
  ///
  /// 同时兼作**登录态校验**: 本地有 MUSIC_U 字符串不代表凭据还有效(过期/被踢/从别处
  /// 拷了数据目录). 只有服务端明确回 auth 错才清登录态 —— 网络/风控失败不动, 免得
  /// 一次网络抖动就把人踢下线.
  Future<void> syncAccount() async {
    try {
      await rust.accountSyncActive();
    } catch (e) {
      // 结构化错误直接看 kind(FfiError.auth); 不再靠文本前缀 contains
      if (errorKind(e) != 'auth') return;
      try {
        await rust.logout();
        await refreshInfo();
        toast('登录状态已失效, 请重新登录');
      } catch (_) {}
    }
  }

  /// 退出登录; thenLogin=true 表示切换账号(退出后立刻再开授权页)
  Future<void> logout({bool thenLogin = false}) async {
    try {
      // 同 switchAccount: 先抓上一个账号的缓存键, 登出后 session 里就查不到了。
      final previousKey = await DailyPlaylistCache.resolveAccountKey();
      await auth.logout();
      // 本来就没登录时 previousKey 是匿名分区: 没别人的数据要清, 留着还省一次网络。
      if (previousKey != DailyPlaylistCache.anonymousKey) {
        unawaited(purgeDailyCache(previousKey));
      }
      await refreshInfo();
      if (!isMounted()) return;
      toast(thenLogin ? '已退出, 请登录另一个账号' : '已退出登录(账号仍留在账号簿)');
      if (thenLogin) await login();
    } catch (e) {
      if (!isMounted()) return;
      toastError('退出登录失败: ${friendlyError(e)}');
    }
  }

  /// 拉一次"我喜欢的音乐"的 id 集合. 失败不影响播放, 只是红心状态未知。
  Future<void> loadLiked() async {
    try {
      final ids = await retryNetwork(rust.likedIds);
      if (!isMounted()) return;
      setLiked(ids.toSet());
    } catch (_) {}
  }

  // ---------------- 日推缓存(按账号分区) ----------------

  /// 每日推荐歌单(带本地缓存): 同一天第二次进页面直接读缓存, 离线也能出内容。
  ///
  /// 缓存口径见 `daily_cache.dart` 与 设置 → 缓存(保留天数 / 立即清理)。
  /// 未初始化(dataDir 未知)或用户关掉缓存时原样透传, 行为与没有缓存一致。
  Future<List<rust.Playlist>> dailyPlaylists() async {
    final dir = infoOf()?.dataDir;
    if (dir == null || dir.isEmpty) return rust.dailyRecommendPlaylists();
    // 缓存目录按账号分区: 日推是账号相关的, 不能把 A 的清单给 B 看。
    return DailyPlaylistCache(
      dataDir: dir,
      accountKey: await DailyPlaylistCache.resolveAccountKey(),
    ).load(
      fetch: rust.dailyRecommendPlaylists,
      keepDays: AppSettings.instance.dailyCacheDays,
    );
  }

  /// 历史日推里要合并的本地缓存天(设置 → 每日推荐歌单缓存; 0 天 = 关闭时返回空)。
  Future<List<DailyCacheDay>> dailyLocalDays() async {
    final dir = infoOf()?.dataDir;
    if (dir == null || dir.isEmpty) return const [];
    if (AppSettings.instance.dailyCacheDays <= 0) return const [];
    // 历史日推只合并**当前账号**的本地天: 别的账号的天不算"我的历史"。
    return DailyPlaylistCache(
      dataDir: dir,
      accountKey: await DailyPlaylistCache.resolveAccountKey(),
    ).days();
  }

  /// 清掉**某个账号**的每日推荐歌单缓存(登出/切号时对上一个账号做一次)。
  ///
  /// 缓存本身已按 uid 分区(见 `daily_cache.dart`), 这里再删一遍是为了不把上一个
  /// 账号的日推清单留在这台设备上 —— 换人用同一台机器时不该翻得到别人的推荐。
  Future<void> purgeDailyCache(String accountKey) async {
    final dir = infoOf()?.dataDir;
    if (dir == null || dir.isEmpty) return;
    await DailyPlaylistCache.purgeAccount(dataDir: dir, accountKey: accountKey);
  }

  // ---------------- 二级页导航(原 G9) ----------------

  /// 打开"关注/粉丝"列表(当前账号)
  Future<void> openUserList({required bool startOnFans}) async {
    if (infoOf()?.loggedIn != true) {
      toast('登录后才能查看关注与粉丝');
      return;
    }
    await showUserList(contextOf(), startOnFans: startOnFans);
  }

  /// 打开歌单详情页(全屏路由): 曲目/收藏/分享/评论都在详情页里,
  /// 不再把曲目塞进搜索页列表。
  Future<void> openPlaylist(rust.Playlist pl) async {
    touchInteraction('playlist', pl.id);
    await showPlaylistDetail(
      contextOf(),
      playlistId: pl.id,
      name: pl.name,
      coverUrl: pl.coverUrl,
      special: pl.special,
      loggedIn: infoOf()?.loggedIn == true,
      likedIds: likedOf(),
      currentTrackId: currentTrackIdOf(),
      currentPlaylistId: _queuePlaylistId,
      onLikeChanged: markLiked,
    );
  }

  /// 解析"我喜欢的音乐"歌单 id(缓存). 失败静默: 只是"定位正在播放"少一个依据.
  Future<void> resolveLikedPlaylistId() async {
    if (_likedPlaylistId != null) return;
    try {
      final pls = await rust.myPlaylists();
      for (final p in pls) {
        if (p.special) {
          if (isMounted()) {
            _likedPlaylistId = p.id;
            notifyListeners();
          }
          return;
        }
      }
    } catch (_) {
      // 未登录/网络异常: 下次进"我喜欢的音乐"详情时再试
    }
  }

  /// 从"我的"页打开"我喜欢的音乐"详情(要用 myPlaylists 找到这个歌单的 id)
  Future<void> openLikedDetail() async {
    if (infoOf()?.loggedIn != true) {
      toast('登录后才能查看我喜欢的音乐');
      return;
    }
    setSearchBusy(true);
    try {
      final pls = await retryNetwork(rust.myPlaylists);
      if (!isMounted()) return;
      rust.Playlist? found;
      for (final p in pls) {
        if (p.special) {
          found = p;
          break;
        }
      }
      final sp = found;
      if (sp == null) {
        toast('没有找到"我喜欢的音乐"歌单');
        return;
      }
      _likedPlaylistId = sp.id;
      await showPlaylistDetail(
        contextOf(),
        playlistId: sp.id,
        name: '我喜欢的音乐',
        coverUrl: sp.coverUrl,
        special: true,
        loggedIn: infoOf()?.loggedIn == true,
        likedIds: likedOf(),
        currentTrackId: currentTrackIdOf(),
        currentPlaylistId: _queuePlaylistId,
        onLikeChanged: markLiked,
      );
    } catch (e) {
      if (!isMounted()) return;
      toast(friendlyError(e));
    } finally {
      if (isMounted()) setSearchBusy(false);
    }
  }
}
