import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../app_meta.dart';
import '../app_settings.dart';
import '../app_sheet.dart';
import '../app_shell.dart';
import '../audio_tuning.dart';
import '../desktop_integration.dart';
import '../desktop_shell.dart';
import '../keystore.dart';
import '../net_retry.dart';
import '../playback.dart';
import '../release_notes.dart';
import '../rust/api_all.dart' as rust;
import '../song_actions.dart';
import '../toast.dart' show showToast;
import '../update_checker.dart';
import '../update_dialog.dart';
import 'account_actions.dart';
import 'playback_coordinator.dart';
import 'search_controller.dart' as search_state;

/// 首页的**启动/外壳编排**(拆 `home_page.dart` §7.7 第二刀)。
///
/// 搬的是什么(逐行等价搬运, 不改 await 顺序/不改"先 Keystore 再 Core"的时序/
/// 不改帧后弹窗的时机):
/// - [bootstrap](原 `_bootstrap`): 冷启动恢复 —— dataDir → Keystore restore →
///   `rust.init` → 设置加载 → 更新检查/播放参数/缓存上限 → 播放现场恢复 →
///   搜索历史/落地页/猜你想搜预热 → 桌面集成/桌面壳接线 → 已登录则拉账号与红心;
/// - [bindDesktopShell](原 `_bindDesktopShell`): Linux 桌面「点关闭 = 退出 /
///   隐藏到托盘」接线与托盘能力回读;
/// - [offerDesktopIntegration](原 `_offerDesktopIntegration`): AppImage 首启
///   问一次「集成到应用菜单」;
/// - [onUpdatePrompt](原 `_onUpdatePrompt`): 启动检查发现新版本时的弹窗
///   (Settings 决定每天/每周/每月, 同一次运行只弹一次);
/// - [onAudioSettingsChanged](原 `_onAudioSettingsChanged`): 设置里播放参数/
///   响度/缓存上限变化的调参节流(只在值真的变了才调 FFI)。
///
/// 边界(为什么能搬):
/// - **不持有页面状态**: 登录态快照/错误横幅/动作宿主都按回调写回页面
///   ([setInfo] / [setError] / [buildActionsHost]), 页面那边仍是唯一真相;
/// - **不持有 BuildContext**: 需要时经 [contextOf] 在调用瞬间取, 存活判定走
///   [isMounted](与拆分前 `mounted` 同义);
/// - **不碰 UI 结构**: 只弹已有的对话框/toast, 不改 build 顺序。
class HomeStartup {
  HomeStartup({
    required this.playback,
    required this.coordinator,
    required this.account,
    required this.search,
    required this.buildActionsHost,
    required this.desktopClose,
    required this.contextOf,
    required this.isMounted,
    required this.setInfo,
    required this.setError,
  });

  /// 播放器门面(只用来取 dataDir; 播放态快照在 [PlaybackCoordinator])
  final Playback playback;

  /// 播放协调器(启动恢复现场 + 响度增益状态)
  final PlaybackCoordinator coordinator;

  /// 账号/浏览态动作(启动时同步账号簿、拉红心、解析「我喜欢的音乐」歌单 id)
  final AccountActions account;

  /// 搜索状态机(启动时预热历史/落地页/「猜你想搜」)
  final search_state.SearchController search;

  /// "..." 菜单的动作宿主(登录态落地后刷新槽位)
  final SongActionHost Function() buildActionsHost;

  /// 「关闭主窗口」行为的分流点(托盘降级提示挂在它上面)
  final DesktopCloseObserver desktopClose;

  /// 调用瞬间取 BuildContext(本类不持有)
  final BuildContext Function() contextOf;

  /// 页面是否还活着(与拆分前 `mounted` 同义)
  final bool Function() isMounted;

  /// 登录态快照回灌页面(原 `setState(() => _info = info)`)
  final void Function(rust.InitInfo info) setInfo;

  /// 错误横幅回灌页面(原 catch 里的 `setState(() => _error = ...)`)
  final void Function(String message) setError;

  /// 已经弹过更新提示的版本 tag(同一次运行只弹一次, 避免重复打扰)
  String? _promptedUpdateTag;

  /// 播放参数变化时才真的调 FFI(设置页里每拖一格 Slider 都会 notifyListeners)
  AudioTuningRequest? _lastTuning;
  int? _lastCacheLimitMb;
  bool? _lastLoudnessNormalize;
  double? _lastLoudnessTarget;

  Future<void> bootstrap() async {
    try {
      final dir = await playback.dataDir();
      // Android Keystore 凭据桥: 先 restore(幂等, 非 Android/不可用则跳过)再开 Core,
      // 否则 Core::open 选不到后端(见 docs/android-keystore-wiring-design.md).
      await credentialSync.ensureRestored();
      final info = await rust.init(dataDir: dir);
      await AppSettings.instance.load(info.dataDir);
      // 登录期可能产生 pending, 启动点落一次 Keystore
      unawaited(credentialSync.drainPending());
      // 首帧后 3s 后台静默检查更新(节流/开关在 update_checker 内, 失败静默)
      unawaited(runStartupUpdateCheck(AppSettings.instance));
      // 更新后首次启动: 已装上的这个版本有什么新特性(每个版本只弹一次)。
      // 必须在 AppSettings.load 之后(要看 announcedVersion / hadStoredSettings)。
      unawaited(promptWhatsNew());
      // 启动时把已保存的播放参数与缓存上限应用一次(默认值 = 不改变现状)
      unawaited(applyAudioTuning());
      unawaited(enforceCacheLimit());
      if (!isMounted()) return;
      setInfo(info);
      publishActionsHost(contextOf(), buildActionsHost());
      // 状态记忆: 恢复上次退出时的队列与曲目(只恢复现场, 不自动出声)
      unawaited(coordinator.restoreFromDisk(info.dataDir));
      // 本地历史和热词都依赖 init() 建立的 Core, 必须等初始化完成再拉
      unawaited(search.loadHistory());
      unawaited(search.loadLanding());
      // 「猜你想搜」候选池: 预热一次(进搜索页时会按 10 分钟 TTL 再决定是否重拉)
      unawaited(search.refreshRecommended());
      // AppImage 首启: 问一次「集成到应用菜单」(deb 安装的走不到这条)
      unawaited(offerDesktopIntegration(info.dataDir));
      // Linux 桌面: 把「点关闭 = 退出 / 隐藏到托盘」推给 GTK runner(其它平台 no-op)
      unawaited(bindDesktopShell());
      // 已登录就把账号记进账号簿(老版本登录过的账号也能被记住)
      if (info.loggedIn) {
        unawaited(account.syncAccount());
        unawaited(account.loadLiked());
        unawaited(account.resolveLikedPlaylistId());
      }
    } catch (e) {
      setError(friendlyError(e));
    }
  }

  /// Linux 桌面: 绑定「关闭主窗口」行为(退出 / 隐藏到托盘)并读回托盘能力。
  ///
  /// 核心价值是"关到托盘不停播放": 隐藏窗口不动进程与 Dart isolate, Rust 音频线程
  /// 继续跑; 只有托盘菜单「退出」才真的终止进程。没有托盘宿主时原生会降级成
  /// "最小化到任务栏"并通过 closeToTaskbarFallback 通知这里提示一次。
  Future<void> bindDesktopShell() async {
    final shell = DesktopShell.instance;
    desktopClose.onFallbackToTaskbar = () {
      if (!isMounted()) return;
      showToast(contextOf(), '当前桌面没有托盘, 已最小化到任务栏');
    };
    final trayStatus = await shell.bindSettings(AppSettings.instance);
    if (!isMounted()) return;
    if (AppSettings.instance.closeBehavior == CloseBehavior.minimizeToTray &&
        trayStatus.degraded) {
      showToast(contextOf(), '本机没有可用的系统托盘, 关闭窗口将最小化到任务栏');
    }
  }

  /// Linux AppImage 首启: 问一次「是否集成到应用菜单」(§11.A-2)。
  ///
  /// 判据全部是纯函数(`desktop_integration.dart`), 这里只负责弹窗、落标记与提示。
  /// 拒绝/失败都落标记 —— 以后不再骚扰; 安装只是用户目录下的两份文件, 不需要 root。
  Future<void> offerDesktopIntegration(String dataDir) async {
    final pending = await desktopIntegrationPending(dataDir: dataDir);
    if (pending == null || !isMounted()) return;
    final home = Platform.environment['HOME'] ?? '';
    if (home.isEmpty) return;
    final agree = await showAppDialog<bool>(
      contextOf(),
      builder: (ctx) => AlertDialog(
        title: const Text('集成到应用菜单?'),
        content: const Text(
          '当前以 AppImage 方式运行, 系统菜单里还没有轻音 MiniNCM。\n'
          '是否写入菜单入口与图标? (只改你自己的 ~/.local/share, 不需要管理员权限, '
          '以后不想要了直接删掉那两个文件即可)',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('不用了'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('集成'),
          ),
        ],
      ),
    );
    if (!isMounted()) return;
    if (agree != true) {
      await markDesktopIntegrationAsked(dataDir);
      return;
    }
    final r = await installDesktopIntegration(
      appImagePath: pending.appImagePath,
      home: home,
      version: kAppVersion,
    );
    if (!isMounted()) return;
    if (r.ok) {
      showToast(contextOf(), r.iconInstalled ? '已添加到应用菜单' : '已添加菜单入口(未找到图标)');
    } else {
      await markDesktopIntegrationAsked(dataDir);
      if (!isMounted()) return;
      showToast(contextOf(), '集成失败: ${r.error ?? '未知错误'}', isError: true);
    }
  }

  /// 更新后首次启动的「本次更新」公告。
  ///
  /// 口径:
  /// - 当前版本在 [kReleaseHighlights] 里没有条目 ⇒ 不弹(不是每个 patch 都值得说);
  /// - 同一个版本只弹一次([AppSettings.announcedVersion] 记下);
  /// - **全新安装不弹**([AppSettings.hadStoredSettings] = false): 用户没有"上次版本",
  ///   弹一句"已更新到 X"只会让人困惑。
  Future<void> promptWhatsNew() async {
    final settings = AppSettings.instance;
    if (!settings.hadStoredSettings) return;
    final tag = normalizeVersionKey(kAppVersion);
    if (settings.announcedVersion == tag) return;
    final highlights = highlightsFor(tag);
    if (highlights.isEmpty) return;
    // 等首帧: 此时 MaterialApp/Localizations 已就绪, 且不会打断 init 阶段的布局。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!isMounted()) return;
      await settings.markAnnounced(tag);
      await showWhatsNewDialog(
        contextOf(),
        version: kAppVersion,
        highlights: highlights,
      );
    });
  }

  /// 启动自动检查发现新版本时的弹窗(每天/每周/每月由 AppSettings 决定)。
  void onUpdatePrompt() {
    final info = UpdateCheckHost.pendingPrompt.value;
    if (info == null || !info.isNewer) return;
    if (info.latest == _promptedUpdateTag) return;
    _promptedUpdateTag = info.latest;
    // 立即清掉, 避免同一次通知重入; 红点仍由 pendingUpdate 维护。
    UpdateCheckHost.pendingPrompt.value = null;
    if (!isMounted()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!isMounted()) return;
      await showUpdateDialog(contextOf(), info);
    });
  }

  void onAudioSettingsChanged() {
    final settings = AppSettings.instance;
    // 响度均衡的开关/目标电平变化 ⇒ 已算好的每曲增益全部作废, 当前曲目重算
    final loudnessChanged =
        settings.loudnessNormalize != _lastLoudnessNormalize ||
        settings.loudnessTargetLufs != _lastLoudnessTarget;
    _lastLoudnessNormalize = settings.loudnessNormalize;
    _lastLoudnessTarget = settings.loudnessTargetLufs;
    if (loudnessChanged) {
      forgetLoudnessGain();
      final id = coordinator.player?.trackId?.toInt();
      if (id != null) {
        coordinator.markLoudnessApplied(id);
        unawaited(applyLoudnessForTrack(id));
      }
      return;
    }
    final request = AudioTuningRequest.fromSettings(settings);
    if (request != _lastTuning) {
      _lastTuning = request;
      unawaited(applyAudioTuning());
    }
    if (settings.cacheLimitMb != _lastCacheLimitMb) {
      _lastCacheLimitMb = settings.cacheLimitMb;
      unawaited(
        enforceCacheLimit(keepTrackId: coordinator.player?.trackId?.toInt()),
      );
    }
  }
}
