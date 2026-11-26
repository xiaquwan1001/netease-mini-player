import 'dart:async';

import 'package:flutter/widgets.dart';

import '../app_settings.dart';
import '../desktop_shell.dart';
import '../app_shell.dart';
import '../artist_nav.dart';
import '../playback.dart';
import '../player_bar.dart';
import '../search_focus.dart';
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
/// | 聚焦搜索(Ctrl+F / `/`) | [searchFocusSlot].value = 回调 | = null |
///
/// **多实例语义**: attach 仍是"后建覆盖先建"; 区别只在销毁时不再把槽位留给下一个
/// 实例, 而是按 attach 顺序**交还**给仍然活着的上一个([_alive] 栈)。
///
/// 为什么是栈而不是"最近一次 attach"的单指针(U-06): 单指针只记最后一个, 于是
/// `A attach → B attach → B detach` 时主人直接变 null ⇒ 全局槽位被清空,
/// 而 A 明明还活着(它的监听器都还挂着), 通知栏/耳机键/托盘/"..."菜单/播放条回调
/// 全部失效(要等下一个 HomePage 实例把槽位重新装上)。栈让 B 走掉时把所有权还给 A。
///
/// 不会在"真实多页面"下退化: 生产里同一时刻只有一个 HomePage 实例在树上(根 tab
/// 容器就是它), 栈深恒为 1; 栈 >1 只出现在"新实例已 attach、旧实例还没 dispose"
/// 的交接帧(测试里反复建/销毁 HomePage, 或热重启), 那时的正确语义正是
/// "新的拥有槽位, 新的走掉就把槽位还给旧的那个"。也不需要引用计数: 每个实例
/// 的 attach/detach 严格配对([_attached]), 栈里不会有重复项。
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
    required this.onFocusSearch,
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

  /// 桌面上 Ctrl+F / `/` 的落点(退全屏页 → 收浮层 → 切搜索 tab → 聚焦输入框)。
  final VoidCallback onFocusSearch;

  /// 仍然存活的实例, **按 attach 顺序**: 栈顶是当前全局槽位的主人。
  static final List<HomeWiring> _alive = <HomeWiring>[];

  /// 当前主人(栈顶): 只有它销毁时才有权改全局槽位。
  static HomeWiring? get _latest => _alive.isEmpty ? null : _alive.last;

  bool _attached = false;

  /// [buildActionsHost] 的结果: 恢复(交还)时复用同一份, 不重新构造宿主。
  SongActionHost? _host;

  /// 注册全部钩子。重复调用是幂等的(静态 setter/槽位都是覆盖写,
  /// 监听器由 [_attached] 挡住不会重复加)。
  void attach() {
    if (_attached) return;
    _attached = true;
    _alive.remove(this);
    _alive.add(this);
    // 一对 add/remove 的监听器只在这里加(恢复/交还时不加, 否则会重复监听)。
    // 只订阅播放域: 这里只把音量/响度/解码参数推给原生, 与外观/交互记录无关。
    AppSettings.instance.addScopedListener(const {
      AppSettingsDomain.playback,
    }, onAudioSettingsChanged);
    UpdateCheckHost.pendingPrompt.addListener(onUpdatePrompt);
    pageDepth.addListener(onPageDepthChanged);
    // 每次 attach 重新构造动作宿主(登录态可能已变); 交还时复用同一份, 见下。
    _host = buildActionsHost();
    _installSlots();
  }

  /// 把本实例的回调写进进程级槽位。attach 与"上位实例销毁后交还"共用。
  ///
  /// 只碰**覆盖写**的静态 setter/槽位; 那三条 addListener 不在这里(见 [attach])。
  void _installSlots() {
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
    // 宿主建一次就存下: 交还(restore)时写回同一份, 不重复构造。
    _host ??= buildActionsHost();
    ArtistNav.onOpenAlbum = openAlbum;
    // 键事件那一层没有 BuildContext, 只能靠槽位拿到"聚焦搜索"的落点。
    // 这条槽位没有监听者(按下键时才读), 不需要帧后投递。
    searchFocusSlot.value = onFocusSearch;
    // 两个 ValueNotifier 槽位(动作宿主 / 播放条回调)一律**帧后投递**:
    // HomePage.initState 可能发生在 layout 阶段(壳层的 ContentWidthLimit 是
    // LayoutBuilder, 首页首帧因此被压在 layout 里), 同步写槽位会让
    // MaterialApp.builder 里的 ValueListenableBuilder 在构建期被标脏 ⇒
    // 「setState() called during build」(U-08)。
    // 帧前后被销毁/被下一个实例顶掉时都不要写(建完即销毁的实例不该复活成悬挂引用)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_attached || !identical(_latest, this)) return;
      actionsHost.value = _host;
      playerBarActions.value = barActions;
    });
  }

  /// 解绑全部钩子。监听器总是摘掉自己的(闭包引用是本实例的);
  /// 全局槽位只由"当前主人"改 —— 自己不是主人时什么都不碰, 更不会清空。
  void detach() {
    if (!_attached) return;
    _attached = false;
    AppSettings.instance.removeScopedListener(onAudioSettingsChanged);
    UpdateCheckHost.pendingPrompt.removeListener(onUpdatePrompt);
    pageDepth.removeListener(onPageDepthChanged);
    final wasLatest = identical(_latest, this);
    _alive.remove(this);
    if (!wasLatest) return;
    final next = _latest;
    if (next != null) {
      // 交还: A attach → B attach → B detach ⇒ A 重新拥有全局槽位(它还活着)。
      next._installSlots();
      return;
    }
    _clearSlots();
  }

  /// 没有存活实例了: 把进程级槽位恢复成"未注册"状态。
  static void _clearSlots() {
    // 三个 null = 未注册: 原生动作会重新进排队区, 而不是调到已销毁的 State。
    Playback.setSkipHandlers();
    Playback.setActionHandlers();
    // 托盘动作同样摘掉: 这之后点托盘按钮安全 no-op(原生那边通常会先把按钮置灰)。
    DesktopShell.instance.setTrayActionHandlers(null);
    ArtistNav.onOpenAlbum = null;
    searchFocusSlot.value = null;
    // 两个 ValueNotifier 与 [_installSlots] 对称地帧后再清: dispose 也可能发生在
    // 构建/布局阶段(换树时旧 HomePage 的 dispose 与新页面的 build 同属一帧),
    // 同步置 null 同样会命中「setState() called during build」。
    // 帧后若已有新实例接手就什么都别清(谁活着谁拥有槽位)。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_alive.isNotEmpty) return;
      actionsHost.value = null;
      playerBarActions.value = null;
    });
  }
}
