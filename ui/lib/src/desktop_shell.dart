/// Linux 桌面的「关闭主窗口」行为桥: `ncm/desktop_shell` method channel.
///
/// 原生侧在 `ui/linux/runner/my_application.cc`(GTK + 运行期 dlopen 的
/// libayatana-appindicator3)。这里做四件事:
///   1. 把 [AppSettings.closeBehavior] 推给原生(启动一次, 之后每次改设置推一次);
///   2. 读回原生能力快照([TrayStatus]): 有托盘 / 缺库 / 缺 StatusNotifier 宿主;
///   3. **关闭请求的分流点**: Flutter 的 FlView 自己连了窗口的 delete-event 并调
///      fl_engine_request_app_exit(信号到不了 runner), 所以"点关闭"最终落在 Dart 的
///      [WidgetsBindingObserver.didRequestAppExit]: 退出 ⇒ AppExitResponse.exit,
///      隐藏 ⇒ 调原生 hideToTray 后 AppExitResponse.cancel。这是官方支持的路径,
///      也不需要去 GTK 侧跟引擎抢 delete-event(实测抢不到: 回调一次都不会被调用);
///   4. 提供 [DesktopCloseObserver] 供首页注册(见 home_page.dart 的 initState)。
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

  Future<Object?> _onNativeCall(MethodCall call) async => null;
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
