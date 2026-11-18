/// Linux 桌面的「关闭主窗口」行为桥: `ncm/desktop_shell` method channel.
///
/// 原生侧在 `ui/linux/runner/my_application.cc`(GTK + 运行期 dlopen 的
/// libayatana-appindicator3)。这里做五件事:
///   1. 把 [AppSettings.closeBehavior] 推给原生(启动一次, 之后每次改设置推一次);
///   2. 读回原生能力快照([TrayStatus]): 有托盘 / 缺库 / 缺 StatusNotifier 宿主;
///   3. **关闭请求的分流点**: Flutter 的 FlView 自己连了窗口的 delete-event 并调
///      fl_engine_request_app_exit(信号到不了 runner), 所以"点关闭"最终落在 Dart 的
///      [WidgetsBindingObserver.didRequestAppExit]: 退出 ⇒ AppExitResponse.exit,
///      隐藏 ⇒ 调原生 hideToTray 后 AppExitResponse.cancel。这是官方支持的路径,
///      也不需要去 GTK 侧跟引擎抢 delete-event(实测抢不到: 回调一次都不会被调用);
///   4. 提供 [DesktopCloseObserver] 供首页注册(见 home_page.dart 的 initState);
///   5. **托盘播放控制**: 原生菜单里的「播放/暂停·上一首·下一首·喜欢」只发意图
///      ([TrayActionNames] → [TrayActionHandlers]), 真正的播放控制在 Dart; 反方向由
///      [DesktopShell.setPlaybackState] 把播放态/喜欢态推回去, 原生据此改文案与置灰。
///
/// 为什么能力探测放在原生: 只有原生能查会话总线上的 org.kde.StatusNotifierWatcher、
/// 也只有原生知道 dlopen 到没到 libayatana-appindicator3。Dart 侧不猜。
///
/// 非 Linux 平台(Android/Windows)不调通道: Android 没有"关窗口"这回事, Windows 本轮
/// 未实现 —— [bindSettings] 在非 Linux 上直接返回, 通道异常也一律吞掉(降级不崩)。
library;

import 'dart:async';
import 'dart:io';

// AppExitResponse 定义在 dart:ui(Flutter 的 System.requestAppExit 响应枚举)。
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_settings.dart';

/// 原生能力快照(来自原生 `getStatus`)。
@immutable
class TrayStatus {
  const TrayStatus({
    required this.trayAvailable,
    required this.libAppIndicator,
    required this.closeToTray,
    required this.reason,
  });

  /// 还没问过原生(非 Linux / 通道不可用)。
  const TrayStatus.unknown()
    : trayAvailable = false,
      libAppIndicator = false,
      closeToTray = false,
      reason = 'unknown';

  /// 现在点关闭能真的隐藏到托盘(库 + 宿主都在)。
  final bool trayAvailable;

  /// 运行期是否 dlopen 到了 libayatana-appindicator3(与宿主无关)。
  final bool libAppIndicator;

  /// 原生侧当前认为的关闭行为(tray = 隐藏)。
  final bool closeToTray;

  /// `ok` / `no-libappindicator` / `no-status-notifier-host` / `unknown`。
  final String reason;

  bool get known => reason != 'unknown';

  /// 降级状态: 用户选了"最小化到托盘", 但这台机器上只能最小化到任务栏。
  bool get degraded => !trayAvailable;

  /// 解析原生返回的 map(宽容: 字段缺失/类型不对都按不可用处理, 不抛)。
  static TrayStatus fromChannel(Object? raw) {
    if (raw is! Map) return const TrayStatus.unknown();
    bool asBool(Object? v) => v is bool && v;
    final reason = raw['reason'];
    return TrayStatus(
      trayAvailable: asBool(raw['trayAvailable']),
      libAppIndicator: asBool(raw['libAppIndicator']),
      closeToTray: asBool(raw['closeToTray']),
      reason: reason is String && reason.isNotEmpty ? reason : 'unknown',
    );
  }

  @override
  String toString() =>
      'TrayStatus(trayAvailable: $trayAvailable, lib: $libAppIndicator, '
      'closeToTray: $closeToTray, reason: $reason)';
}

/// 设置项副标题(纯函数, 便于单测断言"文案不撒谎")。
///
/// - 非 Linux: 明说"仅 Linux 生效", 不给用户"Windows 也能这样"的错觉;
/// - 选了直接退出: 说清与旧版一致;
/// - 选了托盘且托盘可用: 说清"播放继续"这个核心价值;
/// - 选了托盘但托盘不可用: 明说会降级成最小化到任务栏(而不是假装成功)。
String closeBehaviorSubtitle({
  required CloseBehavior behavior,
  required TrayStatus status,
  required bool linux,
}) {
  if (!linux) {
    return '仅 Linux 桌面生效 · 本平台关闭窗口仍然是直接退出(Windows 端暂未实现)';
  }
  if (behavior == CloseBehavior.quit) {
    return '点关闭按钮 / Alt+F4 直接退出(与旧版一致), 同时停止播放';
  }
  if (status.trayAvailable) {
    return '点关闭按钮只隐藏主窗口, 后台继续播放; 用托盘图标恢复或退出';
  }
  return switch (status.reason) {
    'no-libappindicator' => '当前系统缺少 libayatana-appindicator3, 将降级为最小化到任务栏',
    'no-status-notifier-host' => '当前桌面没有托盘宿主(StatusNotifier), 将降级为最小化到任务栏',
    _ => '当前桌面没有可用的系统托盘, 将降级为最小化到任务栏',
  };
}

/// 通道名(与原生 `kDesktopChannelName` 一致)。
const MethodChannel kDesktopShellChannel = MethodChannel('ncm/desktop_shell');

/// 托盘菜单动作名 —— **与原生 `my_application.cc` 的 kTrayAction* 是同一份表**,
/// 改一边必须同步另一边(两边注释互指):
///
/// | 常量 | 原生菜单项 | Dart 侧落到哪个已有入口 |
/// |---|---|---|
/// | [togglePlay] | 播放 / 暂停 | 播放控制器的 toggle(与播放条按钮同一个) |
/// | [previous] | 上一首 | 队列上一首(与通知栏/耳机键同一个回调) |
/// | [next] | 下一首 | 队列下一首(同上) |
/// | [toggleLike] | 喜欢 / 取消喜欢 | 当前曲目的红心切换(同上) |
///
/// 原生只发意图: 队列、喜欢列表、登录态都只有 Dart 一份, 原生不复制也不猜。
abstract final class TrayActionNames {
  static const String togglePlay = 'togglePlay';
  static const String previous = 'previous';
  static const String next = 'next';
  static const String toggleLike = 'toggleLike';
}

/// 托盘菜单动作(解析后的稳定枚举; 未知动作解析成 null)。
enum TrayAction {
  togglePlay(TrayActionNames.togglePlay),
  previous(TrayActionNames.previous),
  next(TrayActionNames.next),
  toggleLike(TrayActionNames.toggleLike);

  const TrayAction(this.id);

  /// 通道里传的字符串(与原生常量逐字一致)。
  final String id;

  /// 动作名 → 枚举。大小写/空白都不做特判: 认不出就是 null(两端口径漂了)。
  static TrayAction? tryParse(Object? raw) {
    if (raw is! String) return null;
    for (final action in TrayAction.values) {
      if (action.id == raw) return action;
    }
    return null;
  }
}

/// 托盘动作 → **已有**播放控制回调的映射表(纯数据 + 纯分发, 便于单测)。
///
/// 为什么这里全是可空回调: 首页没建/已销毁、未登录、没有队列时, 这些入口本来就不
/// 该被调 —— 此时 [dispatch] 安全 no-op 并返回 false(不抛、不 toast、不假装成功)。
/// 原生侧靠 [DesktopShell.setPlaybackState] 推过去的 hasTrack 把不可用项置灰,
/// 这里再兜一层, 避免"点了置灰失败的项 ⇒ 异常"。
@immutable
class TrayActionHandlers {
  const TrayActionHandlers({
    this.onTogglePlay,
    this.onPrevious,
    this.onNext,
    this.onToggleLike,
  });

  final VoidCallback? onTogglePlay;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onToggleLike;

  /// 某个动作当前有没有注册回调(没有 ⇒ 原生把它置灰最合适)。
  bool handles(TrayAction action) => _handlerOf(action) != null;

  VoidCallback? _handlerOf(TrayAction action) => switch (action) {
    TrayAction.togglePlay => onTogglePlay,
    TrayAction.previous => onPrevious,
    TrayAction.next => onNext,
    TrayAction.toggleLike => onToggleLike,
  };

  /// 分发一个动作。返回是否真的执行了(未注册回调 ⇒ false)。
  bool dispatch(TrayAction action) {
    final handler = _handlerOf(action);
    if (handler == null) return false;
    handler();
    return true;
  }
}

/// Linux 关闭行为/托盘桥。默认单例 [instance]; 单测可 new 一个注入假通道。
class DesktopShell {
  DesktopShell({MethodChannel? channel})
    : _channel = channel ?? kDesktopShellChannel {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  static final DesktopShell instance = DesktopShell();

  final MethodChannel _channel;

  /// 原生能力快照(设置页据此给副标题)。非 Linux 永远是 unknown。
  final ValueNotifier<TrayStatus> status = ValueNotifier<TrayStatus>(
    const TrayStatus.unknown(),
  );

  AppSettings? _settings;
  bool _pushing = false;

  /// 托盘动作的落点(首页 attach 时注册, detach 时清空 ⇒ 无页面即 no-op)。
  TrayActionHandlers? _trayHandlers;

  /// 最近一次**成功**推给原生的托盘按钮态: 值没变就不跨通道(整页重建时会频繁调)。
  bool? _sentPlaying;
  bool? _sentLiked;
  bool? _sentHasTrack;

  /// 这个平台有没有桌面壳通道(只有 Linux 有)。
  static bool get isSupportedPlatform => !kIsWeb && Platform.isLinux;

  /// 启动时调用一次: 读回能力快照, 并把已落盘的关闭行为推给原生。
  Future<TrayStatus> refresh() async {
    if (!isSupportedPlatform) return status.value;
    try {
      final raw = await _channel.invokeMethod<Object?>('getStatus');
      status.value = TrayStatus.fromChannel(raw);
    } on MissingPluginException {
      status.value = const TrayStatus.unknown();
    } on PlatformException {
      status.value = const TrayStatus.unknown();
    }
    return status.value;
  }

  /// 把设置推给原生。返回原生侧托盘是否真的可用(false = 只能降级)。
  Future<bool> setCloseBehavior(CloseBehavior behavior) async {
    if (!isSupportedPlatform) return false;
    try {
      final active = await _channel.invokeMethod<bool>(
        'setCloseBehavior',
        behavior.id,
      );
      if (active == true) {
        // 原生说托盘活着 ⇒ 顺手把快照刷成可用(不必等下一次 getStatus)
        status.value = TrayStatus(
          trayAvailable: true,
          libAppIndicator: status.value.libAppIndicator,
          closeToTray: behavior == CloseBehavior.minimizeToTray,
          reason: 'ok',
        );
      }
      return active ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 隐藏主窗口到托盘(没有托盘宿主时原生会降级为最小化到任务栏)。
  ///
  /// 返回 true = 真的隐藏到托盘(播放继续), false = 降级为最小化(或原生不可用)。
  Future<bool> hideToTray() async {
    if (!isSupportedPlatform) return false;
    try {
      final hidden = await _channel.invokeMethod<bool>('hideToTray');
      return hidden ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 从托盘恢复主窗口(目前原生自己处理菜单点击, 这里留给"再次启动"等场景)。
  Future<void> showWindow() async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('showWindow');
    } on MissingPluginException {
      // 没有桌面壳: 无事可做
    } on PlatformException {
      // 同上
    }
  }

  /// 注册托盘动作的落点(传 null = 取消注册, 之后的动作安全 no-op)。
  ///
  /// 与 [Playback.setSkipHandlers] 同一口径: 后注册的覆盖先注册的, 首页销毁时清空。
  void setTrayActionHandlers(TrayActionHandlers? handlers) {
    _trayHandlers = handlers;
  }

  /// Dart → 原生: 托盘菜单按钮态(文案 + 置灰)。返回原生侧托盘菜单是否真的活着。
  ///
  /// - [playing] 决定「播放」还是「暂停」, [liked] 决定「喜欢」还是「取消喜欢」;
  /// - [hasTrack] = false(没有当前曲目/播放条还没出现) ⇒ 原生四个按钮全置灰,
  ///   避免点了没反应的"假按钮";
  /// - 幂等: 与上次成功推送的值相同就不跨通道(整页重建/轮询重推因此几乎零成本);
  /// - 失败(非 Linux / 通道缺失 / 缺库)一律静默返回 false, 与关闭行为的降级路径一致。
  Future<bool> setPlaybackState({
    required bool playing,
    required bool liked,
    required bool hasTrack,
  }) async {
    if (!isSupportedPlatform) return false;
    if (_sentPlaying == playing &&
        _sentLiked == liked &&
        _sentHasTrack == hasTrack) {
      return true;
    }
    try {
      final live = await _channel.invokeMethod<bool>('setTrayPlaybackState', {
        'playing': playing,
        'liked': liked,
        'hasTrack': hasTrack,
      });
      _sentPlaying = playing;
      _sentLiked = liked;
      _sentHasTrack = hasTrack;
      return live ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  /// 测试用: 清掉推送幂等缓存(生产路径不需要)。
  @visibleForTesting
  void debugResetPlaybackStateCache() {
    _sentPlaying = null;
    _sentLiked = null;
    _sentHasTrack = null;
  }

  /// 真的退出进程(停播放)。
  Future<void> quit() async {
    if (!isSupportedPlatform) return;
    try {
      await _channel.invokeMethod<void>('quit');
    } on MissingPluginException {
      // 没有桌面壳: 无事可做
    } on PlatformException {
      // 同上
    }
  }

  /// 绑定设置: 立即推一次当前值, 之后每次 [AppSettings] 通知都推(只在值变化时)。
  ///
  /// 失败(没有通道/非 Linux)完全静默: 关闭行为退化为"直接退出", 与旧版一致。
  Future<TrayStatus> bindSettings(AppSettings settings) async {
    if (!isSupportedPlatform) return status.value;
    _settings?.removeListener(_onSettingsChanged);
    _settings = settings;
    settings.addListener(_onSettingsChanged);
    await refresh();
    await _push();
    return status.value;
  }

  void unbindSettings() {
    _settings?.removeListener(_onSettingsChanged);
    _settings = null;
  }

  void _onSettingsChanged() {
    unawaited(_push());
  }

  Future<void> _push() async {
    final settings = _settings;
    if (settings == null || _pushing) return;
    _pushing = true;
    try {
      await setCloseBehavior(settings.closeBehavior);
    } finally {
      _pushing = false;
    }
  }

  /// 原生 → Dart: 目前只有托盘菜单动作("trayAction", 参数是 [TrayActionNames] 里的字符串)。
  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'trayAction') return null;
    final action = TrayAction.tryParse(call.arguments);
    if (action == null) {
      debugPrint('[NCM-TRAY] 未知的托盘动作: ${call.arguments}');
      return null;
    }
    final handlers = _trayHandlers;
    if (handlers == null || !handlers.dispatch(action)) {
      // 没有页面/未登录: 安全 no-op(原生那边本该把这几个按钮置灰)
      debugPrint('[NCM-TRAY] 托盘动作 ${action.id} 没有注册回调, 忽略');
      return null;
    }
    // 留痕: 用户报"点托盘播放没反应"时, 有这条就能分清是原生没发还是 Dart 没接。
    debugPrint('[NCM-TRAY] 托盘动作 ${action.id} 已执行');
    return null;
  }
}

/// 「点关闭按钮」的最终分流点(Flutter 官方路径: `System.requestAppExit`)。
///
/// - 设置是「直接退出」/ 不是 Linux ⇒ [AppExitResponse.exit], 与旧版完全一致(退出即停播放);
/// - 设置是「最小化到托盘」⇒ 让原生隐藏主窗口后 [AppExitResponse.cancel]。
///   不 cancel 的话框架会真的退出进程 —— 那正是要避免的(播放会被打断)。
///   没有托盘宿主时原生降级为最小化到任务栏, 这里弹一次提示(不刷屏)。
class DesktopCloseObserver with WidgetsBindingObserver {
  DesktopCloseObserver({required this.shell, required this.settings});

  final DesktopShell shell;
  final AppSettings settings;

  /// 观察到"没有托盘, 已降级为最小化"时的回调(首页接 toast)。
  VoidCallback? onFallbackToTaskbar;

  /// 降级提示只弹一次, 避免每次关窗口都刷屏。
  bool _fallbackNotified = false;

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    if (!DesktopShell.isSupportedPlatform) return AppExitResponse.exit;
    if (settings.closeBehavior == CloseBehavior.quit) {
      return AppExitResponse.exit;
    }
    final hiddenToTray = await shell.hideToTray();
    if (!hiddenToTray && !_fallbackNotified) {
      _fallbackNotified = true;
      onFallbackToTaskbar?.call();
    }
    return AppExitResponse.cancel;
  }
}
