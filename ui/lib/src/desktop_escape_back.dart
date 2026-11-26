import 'dart:async' show unawaited;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'player_bar.dart' show isDesktopPlatform;

/// 桌面(Linux/Windows)键盘返回: **Esc = 退一层**。
///
/// 为什么需要(2026-11-26 Linux 交互审查): Flutter 的返回语义只接到
/// `SystemNavigator`/`PopScope` 那条链上(Android 返回键、手势), 桌面没有对应信号 ——
/// 实测在「关于」页按 Esc, 前后两帧像素完全相同(什么都不发生)。桌面用户的预期是
/// Esc = 关闭/返回, 而路由栈的退层优先级(歌词 → 右栏 → tab → 歌单浏览态)已经由
/// [HomeBackGuard] 的 `PopScope` 表达过一次; 所以这里**不复制**那套判定, 只把 Esc
/// 接到 `Navigator.maybePop()`: 栈顶是二级页就 pop 它, 栈顶是首页就让首页的
/// PopScope 接管(与 Android 返回键逐字节同一套语义)。
///
/// 两条边界:
/// - **焦点在文本框里 ⇒ 只收焦点, 不 pop**(否则在搜索框里按 Esc 会把整页退掉);
/// - 非桌面平台完全不挂 handler(Android 有自己的返回键, iOS/macOS 不归本仓维护)。
///
/// 用 `HardwareKeyboard.addHandler` 而不是 `Shortcuts`/`Focus`: 后者的按键分发从
/// `primaryFocus` 开始, 页面上没有任何焦点节点时(桌面最常见)根本走不到根部的
/// Shortcuts —— 实测那样按 Esc 也是零反应。
class DesktopEscapeBack extends StatefulWidget {
  const DesktopEscapeBack({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  /// 根 Navigator 的 key(桌面 Esc 要能拿到它; 见 app_shell.dart 的 `rootNavigatorKey`)。
  final GlobalKey<NavigatorState> navigatorKey;

  final Widget child;

  @override
  State<DesktopEscapeBack> createState() => _DesktopEscapeBackState();
}

class _DesktopEscapeBackState extends State<DesktopEscapeBack> {
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
    // 只认按下: 长按的 KeyRepeatEvent 会连退好几层
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    final focus = FocusManager.instance.primaryFocus;
    if (escapeTargetsTextInput(focus)) {
      focus?.unfocus();
      return true;
    }
    final navigator = widget.navigatorKey.currentState;
    if (navigator == null) return false;
    // maybePop 是异步的(要等 route 的 willPop 判定); 键事件这里只决定「被消费掉」——
    // 真正退哪一层交给 Navigator/PopScope, 与 Android 返回键同一条路。
    unawaited(navigator.maybePop());
    return true;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Esc 的第一判据: 焦点是不是落在文本输入里(是 ⇒ 只收焦点, 不要退页面)。
///
/// `FocusNode.context` 指向挂焦点的那层 element(`EditableText` 自己), 所以先看自身
/// 再看祖先: 搜索框/歌单筛选框/改签名这些入口都直接或间接包在 `EditableText` 里。
bool escapeTargetsTextInput(FocusNode? node) {
  final context = node?.context;
  if (context == null) return false;
  if (context.widget is EditableText) return true;
  return context.findAncestorWidgetOfExactType<EditableText>() != null;
}
