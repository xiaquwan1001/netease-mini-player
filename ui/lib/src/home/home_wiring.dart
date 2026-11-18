import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_settings.dart';
import '../desktop_shell.dart';
import '../app_shell.dart';
import '../artist_nav.dart';
import '../playback.dart';
import '../player_bar.dart';
import '../song_actions.dart';
import '../update_checker.dart';

/// 首页注册的**进程级静态钩子**的配对入口(拆壳 S8)。
///
/// 这些钩子挂在静态字段/全局 [ValueNotifier] 上, 拆分前只在 initState 里注册、
/// dispose 里只解绑了 PlaybackBridge/AppSettings/UpdateCheckHost/pageDepth 四条,
/// 其余(通知栏回调、动作宿主槽位、播放条回调槽位、[ArtistNav.onOpenAlbum])
/// **留给了下一个实例**, 单测里 HomePage 反复建/销毁时就是悬挂引用。
/// 这里把注册与解绑收成一对, 逐项对应:
///
/// | 钩子 | 注册 | 解绑 |
/// |---|---|---|
/// | 通知栏/耳机键 上一首·下一首·播完 | [Playback.setSkipHandlers] | 传三个 null |
/// | 通知栏自定义按钮(喜欢/模式) | [Playback.setActionHandlers] | 传两个 null |
/// | Linux 托盘播放控制(4 项) | [DesktopShell.setTrayActionHandlers] | 传 null |
/// | 设置变化(播放参数) | addListener | removeListener(同一个引用) |
/// | "..." 动作宿主 | actionsHost.value = 宿主 | actionsHost.value = null |
/// | 播放条回调集合 | playerBarActions.value = 集合 | playerBarActions.value = null |
/// | 艺人页打开专辑 | ArtistNav.onOpenAlbum = 回调 | = null |
/// | 启动检查的更新弹窗 | pendingPrompt.addListener | removeListener |
/// | 根导航层数(底部 tab 让位) | pageDepth.addListener | removeListener |
///
/// **多实例语义与拆分前一致**: attach 仍是"后建覆盖先建"; 区别只在销毁时
/// 会把自己装的那份摘掉。[_latest] 记住最近一次 attach 的实例, 只有它才是
/// 当前全局钩子的主人 —— 旧实例先销毁时不得清掉新实例的绑定。
/// 因此不需要引用计数: 页面在同一时刻只有一个"最新"实例, 全局槽位也只该认一份。
class HomeWiring {
  HomeWiring({
    required this.onNext,
    required this.onPrevious,
    required this.onEnded,
    required this.onToggleLike,
    required this.onCycleMode,
    required this.onTogglePlay,
    required this.buildActionsHost,
    required this.barActions,
    required this.openAlbum,
    required this.onUpdatePrompt,
    required this.onPageDepthChanged,
    required this.onAudioSettingsChanged,
  });

  /// 队列的上一首/下一首(通知栏、耳机键、蓝牙都只发意图)。
  final Future<void> Function() onNext;
  final Future<void> Function() onPrevious;

  /// 原生 STATE_ENDED 的即时通知(自动续播不等 500ms 轮询)。
  final void Function() onEnded;

  /// Linux 托盘菜单「播放 / 暂停」(与播放条上的那个按钮同一个入口)。
  final void Function() onTogglePlay;

  /// 通知栏自定义按钮: 喜欢 / 播放顺序。原生只发意图, 状态与副作用在 Dart。
  final Future<void> Function() onToggleLike;
  final Future<void> Function() onCycleMode;

  /// "..." 菜单的动作宿主(登录态变化时页面会重新 buildHost 后写槽位)。
  final SongActionHost Function() buildActionsHost;

  /// 播放条回调集合(页面只建一次, 跨帧复用同一实例)。
  final PlayerBarActions barActions;

  /// 艺人主页里点专辑的打开动作(需要 BuildContext → 由页面注入)。
  final void Function(BigInt albumId, String albumName, String? coverUrl)
  openAlbum;

  final VoidCallback onUpdatePrompt;
  final VoidCallback onPageDepthChanged;
  final VoidCallback onAudioSettingsChanged;

  /// 最近一次 attach 的实例: 只有它销毁时才有权清空全局槽位。
  static HomeWiring? _latest;

  bool _attached = false;

  /// 注册全部钩子。重复调用是幂等的(静态 setter/槽位都是覆盖写,
  /// 监听器由 [_attached] 挡住不会重复加)。
  void attach() {
    if (_attached) return;
    _attached = true;
    // 顺序与拆分前的 initState 一致: setSkipHandlers 会 flush 排队中的原生动作,
    // 所以必须先注册它再注册 setActionHandlers。
    Playback.setSkipHandlers(
      onNext: onNext,
      onPrevious: onPrevious,
      onEnded: onEnded,
    );
    Playback.setActionHandlers(
      onToggleLike: onToggleLike,
      onCycleMode: onCycleMode,
    );
    // Linux 托盘菜单(播放/暂停·上一首·下一首·喜欢)复用**同一批**回调:
    // 托盘只发意图, 队列与喜欢状态仍然只有 Dart 这一份。非 Linux 平台上是空操作。
    DesktopShell.instance.setTrayActionHandlers(
      TrayActionHandlers(
        onTogglePlay: onTogglePlay,
        onPrevious: () => unawaited(onPrevious()),
        onNext: () => unawaited(onNext()),
        onToggleLike: () => unawaited(onToggleLike()),
      ),
    );
    AppSettings.instance.addListener(onAudioSettingsChanged);
    actionsHost.value = buildActionsHost();
    // 播放条回调槽位只赋这一次(同一实例, 之后不再变); 帧后投递, 避免在
    // initState 所在的构建阶段通知 PlayerBarHost 的祖先。
    // detach 早于这一帧时(建完即销毁的实例)不要把它复活成悬挂引用。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_attached) return;
      playerBarActions.value = playerBarActions.value ?? barActions;
    });
    ArtistNav.onOpenAlbum = openAlbum;
    UpdateCheckHost.pendingPrompt.addListener(onUpdatePrompt);
    pageDepth.addListener(onPageDepthChanged);
    _latest = this;
  }

  /// 解绑全部钩子。监听器总是摘掉自己的(闭包引用是本实例的);
  /// 全局单例槽位只在"我还是最新那个"时清空, 免得把后建实例的绑定清掉。
  void detach() {
    if (!_attached) return;
    _attached = false;
    AppSettings.instance.removeListener(onAudioSettingsChanged);
    UpdateCheckHost.pendingPrompt.removeListener(onUpdatePrompt);
    pageDepth.removeListener(onPageDepthChanged);
    if (!identical(_latest, this)) return;
    _latest = null;
    // 三个 null = 未注册: 原生动作会重新进排队区, 而不是调到已销毁的 State。
    Playback.setSkipHandlers();
    Playback.setActionHandlers();
    // 托盘动作同样摘掉: 这之后点托盘按钮安全 no-op(原生那边通常会先把按钮置灰)。
    DesktopShell.instance.setTrayActionHandlers(null);
    ArtistNav.onOpenAlbum = null;
    actionsHost.value = null;
    playerBarActions.value = null;
  }
}
