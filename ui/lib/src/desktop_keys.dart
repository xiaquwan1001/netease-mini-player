import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'player_bar.dart' show isDesktopPlatform;

/// 桌面(Linux/Windows)的全局键盘: **Esc = 退一层 / 空格 = 播放暂停 / Ctrl+F 或 `/` = 聚焦搜索**。
///
/// 为什么需要(2026-11-26 Linux 交互审查实测): Flutter 的返回只接在
/// `SystemNavigator`/`PopScope` 那条链上(安卓返回键、手势), 桌面没有对应信号 ——
/// 在「关于」页按 Esc, 前后两帧像素完全相同(什么都不发生)。空格与 Ctrl+F 同理, 一条都没接。
///
/// 三条键的落点都**不复制**页面里的判定:
/// - Esc → `Navigator.maybePop()`: 栈顶是二级页就 pop 它; 栈顶是首页就让首页的
///   `PopScope`(HomeBackGuard)接管 —— 歌词 → 右栏 → tab → 歌单浏览态, 与安卓返回键
///   逐字节同一套语义。根路由的 `willPop` 是 `bubble`, 所以栈底按 Esc 不会弹成白屏。
/// - 空格 → `togglePlayback()`(HomePage 投递的播放条 `onToggle`, 与点播放键同一个入口)。
///   **不拿来翻页**: 桌面音乐应用的口径(用户 2026-11-26 拍板), 焦点不在文本输入里时
///   一律被这里吃掉, 列表因此不会因为空格而滚一屏。
/// - Ctrl+F / `/` → `focusSearch()`(HomePage 投递: 退全屏页 → 收回浮层 → 切到搜索 tab
///   → 聚焦输入框)。`/` 在文本框里是普通字符, 不拦。
///
/// 两条边界:
/// - **焦点在文本输入里**: Esc 只 `unfocus()`(不退页), 空格与 `/` 完全不拦(照常输入),
///   Ctrl+F 仍然聚焦搜索(那是"跳到搜索"的语义, 不是插入字符);
/// - 非桌面平台完全不挂 handler(Android 有自己的返回键, iOS/macOS 不归本仓维护)。
///
/// 用 `HardwareKeyboard.addHandler` 而不是 `Shortcuts`/`Focus`: 后者的按键分发从
/// `primaryFocus` 开始, 页面上没有任何焦点节点时(桌面最常见)根本走不到根部的
/// Shortcuts —— 实测那样按 Esc 也是零反应。
class DesktopKeys extends StatefulWidget {
  const DesktopKeys({
    super.key,
    required this.navigatorKey,
    required this.child,
    this.togglePlayback,
    this.focusSearch,
  });

  /// 根 Navigator 的 key(见 app_shell.dart 的 `rootNavigatorKey`)。
  final GlobalKey<NavigatorState> navigatorKey;

  /// 空格要调的"播放/暂停"; 返回 null = 现在没有可切换的播放器(键**不**被吃掉)。
  ///
  /// 传 getter 而不是回调值: 键按下时要拿**当下**的那份回调(页面可能刚重建过)。
  final VoidCallback? Function()? togglePlayback;

  /// Ctrl+F / `/` 要调的"聚焦搜索"; 返回 null = 没有页面接手(键不拦)。
  final VoidCallback? Function()? focusSearch;

  final Widget child;

  @override
  State<DesktopKeys> createState() => _DesktopKeysState();
}

class _DesktopKeysState extends State<DesktopKeys> {
  bool get _enabled => isDesktopPlatform;

  @override
  void initState() {
    super.initState();
    if (_enabled) HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    if (_enabled) HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    // 只认按下: 长按的 KeyRepeatEvent 会连退好几层 / 连切好几首歌
    if (event is! KeyDownEvent) return false;
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    final focus = FocusManager.instance.primaryFocus;
    final inTextInput = escapeTargetsTextInput(focus);

    if (key == LogicalKeyboardKey.escape) {
      if (inTextInput) {
        focus?.unfocus();
        return true;
      }
      final navigator = widget.navigatorKey.currentState;
      if (navigator == null) return false;
      // maybePop 是异步的(要等 route 的 willPop 判定); 键事件这里只决定"被消费掉" ——
      // 真正退哪一层交给 Navigator/PopScope, 与安卓返回键同一条路。
      unawaited(navigator.maybePop());
      return true;
    }

    if (key == LogicalKeyboardKey.space) {
      if (inTextInput || keyboard.isControlPressed || keyboard.isAltPressed) {
        return false;
      }
      final toggle = widget.togglePlayback?.call();
      if (toggle == null) return false;
      toggle();
      return true;
    }

    final ctrlF = key == LogicalKeyboardKey.keyF && keyboard.isControlPressed;
    final slash =
        key == LogicalKeyboardKey.slash &&
        !inTextInput &&
        !keyboard.isControlPressed &&
        !keyboard.isAltPressed;
    if (ctrlF || slash) {
      final focusSearch = widget.focusSearch?.call();
      if (focusSearch == null) return false;
      focusSearch();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Esc/空格/`/` 的第一判据: 焦点是不是落在文本输入里。
///
/// `FocusNode.context` 指向挂焦点的那层 element(`EditableText` 自己), 所以先看自身
/// 再看祖先: 搜索框/歌单筛选框/改签名这些入口都直接或间接包在 `EditableText` 里。
bool escapeTargetsTextInput(FocusNode? node) {
  final context = node?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}
