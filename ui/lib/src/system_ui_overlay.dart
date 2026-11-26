import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemUiOverlayStyle;

/// 系统状态栏 / 手势条的**图标明暗**随 App 主题走(而不是跟着系统深浅色)。
///
/// 为什么需要这一层(审计 2026-11-26 P1#2): 全仓原先一处 `SystemUiOverlayStyle` 都没有,
/// 图标明暗只有两个来源 ——
/// 1. Android 主题 XML(启动窗口, 跟系统深浅色, 见 `res/values{,-night}/styles.xml`);
/// 2. 当前页 **AppBar** 自己算的 `AnnotatedRegion`(Flutter 的 AppBar 按 backgroundColor
///    自动设一份, 见 material/app_bar.dart)。
///
/// 而首页 5 个 tab 里有 4 个根本没有 AppBar(`appBar: topBar` 只在歌词页/歌单浏览态非空,
/// 见 `home/home_page.dart`), 主题又能独立于系统(`AppSettings.themeMode`) ⇒ "系统浅色 +
/// App 深色"冷启动停在推荐页时, 状态栏时钟/电量与手势条是**黑图标压在深色底上**,
/// 而且一直不恢复。
///
/// 挂在 `MaterialApp.builder` 的最外层(在 Navigator 之外): 所有路由(无 AppBar 的首页、
/// 二级页、弹层)都继承这一份; 有 AppBar 的页面仍由 AppBar 自己的 `AnnotatedRegion` 覆盖
/// (它算出来的样式与它自己的底色一致), 这正是期望行为, 不需要去关。
class SystemUiOverlay extends StatelessWidget {
  const SystemUiOverlay({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 深色主题 → 浅色图标(白图标压深底); 浅色主题 → 深色图标。
    final dark = Theme.of(context).brightness == Brightness.dark;
    final iconBrightness = dark ? Brightness.light : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        // 三块颜色全透明: 状态栏/手势条区域露出 App 自己的背景(targetSdk 36 下本来就是
        // edge-to-edge, 这里只是把"透明确立下来", 别让某个平台默认值再涂一层黑/白)。
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        statusBarIconBrightness: iconBrightness,
        systemNavigationBarIconBrightness: iconBrightness,
        // iOS 口径与 Android 相反(对照 SystemUiOverlayStyle.light/dark 两个预设):
        // 深色主题 → statusBarBrightness 为 dark。
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
      ),
      child: child,
    );
  }
}
