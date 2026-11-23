import 'dart:ffi' show Abi;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// arm64 Linux 自带 CJK 字体的判据(2026-11-23)。
///
/// 背景: Flutter 官方发布的 linux-arm64 桌面引擎**没有链 libfontconfig.so.1**
/// (`readelf -d libflutter_linux_gtk.so | grep fontconfig` 无输出; x64 引擎有),
/// 引擎因此拿不到系统字体链 ⇒ 默认字体根本解析不出来, 表现是:
///
/// - CJK 字形一片空白(不是豆腐块, 是空);
/// - 少数带 ASCII 的短标签(如"私人FM"的 `FM`)变成豆腐块 —— 因为系统里没有任何
///   字体可解析, 只有我们挂上的**兜底**字体能出 CJK, 而它不含拉丁;
/// - 同机其它 Flutter 应用(Bettbox)症状一致 ⇒ 不是本项目引入的。
///   上游: flutter/flutter#90951, 修复 PR #180235(需要重编引擎)。
///
/// 我们的绕法: 随包带一份**同时覆盖拉丁 + CJK**的 WenQuanYi Micro Hei
/// (`assets/fonts/`, Apache-2.0), 在**这个平台上把它直接当主字体**
/// (`fontFamily`), 而不只是 fallback —— 否则拉丁字符仍然没人能出。
///
/// 只在 arm64 Linux 生效: x64 Linux / Android / Windows 仍走系统字体,
/// 排版与金标完全不变。上游引擎修好后删掉本文件与 pubspec 的 fonts 段即可。
const String kBundledCjkFamily = 'MiniNcmCjk';

/// 是否需要在主题里使用 [kBundledCjkFamily]。
///
/// 三条都满足才算: 非 Web、是 Linux、CPU 是 arm64。**用 `Abi` 而不是
/// `Platform.version` 字符串匹配**: 后者受内核/发行版文案影响, 前者由 Dart VM 给出。
bool get needsBundledCjkFallback {
  if (kIsWeb) return false;
  if (!Platform.isLinux) return false;
  return Abi.current() == Abi.linuxArm64;
}

/// 主题要用的 fallback 链: 需要兜底时只有一条(自带的 CJK 家族), 否则为空。
///
/// 与 [bundledCjkPrimary] 一起给: 主字体已经覆盖 CJK, fallback 只是防御
/// (比如将来换成只含 CJK 的字体时不会突然出现豆腐块)。
List<String> get bundledCjkFallback =>
    needsBundledCjkFallback ? const [kBundledCjkFamily] : const [];

/// 主题要用的主字体家族: 需要时用自带字体, 否则 null(= 引擎默认/系统字体)。
String? get bundledCjkPrimary =>
    needsBundledCjkFallback ? kBundledCjkFamily : null;
