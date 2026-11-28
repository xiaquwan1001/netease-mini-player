// 轻音 MiniNCM 的入口。
//
// 本文件在拆壳 S8 之后只做两件事: 起 Rust 桥 + 挂 [MiniNcmApp], 以及作为
// **公开符号的门面**。9 个测试文件直接 `import 'package:minincm/main.dart'`,
// 拆文件时用 export 把原来的符号集原样暴露出来, 测试零改动 —— 见
// .pi/plans/arch-audit-frontend-2026-11-15.md §1.2 S8。
//
// 页面主体在 src/home/home_page.dart; 应用外壳/播放条槽位在 src/app_shell.dart;
// 纯逻辑分别在各 src/*.dart。新增符号请直接 import 对应文件, 不要往这里堆。
import 'package:flutter/material.dart';

import 'src/app_settings.dart';
import 'src/app_shell.dart';
import 'src/playback.dart' show Playback;
import 'src/rust/api.dart' as rust;
import 'src/rust/frb_generated.dart';

// 应用外壳 + 常驻播放条槽位(PlayerBarHost 由 MaterialApp.builder 渲染在
// Navigator 之外, 二级页压上来播放条仍在)。
export 'src/app_shell.dart'
    show
        MiniNcmApp,
        NcmRouteObserver,
        PlayerBarHost,
        modalRouteOpen,
        playerBarActions,
        playerBarData,
        playerBarSlot;
// 返回键策略(歌词 → 非首 tab → 歌单浏览态 → 交还系统)。
export 'src/back_policy.dart'
    show HomeBackAction, HomeBackGuard, resolveHomeBackAction;
// 首页(五 tab 壳 + 歌词页 + 歌单浏览态)。
export 'src/home/home_page.dart' show HomePage;
// 逐字歌词来源解析与择优(打分规则唯一实现在 Rust, 见文件头注释)。
export 'src/lyric_source.dart'
    show
        LyricSourceLoaders,
        ResolvedLyric,
        WordLyricScore,
        chooseWordSource,
        lyricSourceLabel,
        resolveLyricSource,
        scoreWordLyric,
        yrcWordGoodEnough;
// 通知栏: 播放顺序轮转 + 自定义按钮图标。
export 'src/notification_mode.dart'
    show nextNotificationMode, notificationModeIcon;

Future<void> main() async {
  // 必须在用任何 MethodChannel 之前: `MainActivity` 的 `ncm/player` 通道要 binding 已初始化
  // (2026-11-28 实测: 缺这一行 ⇒ Android 上 `playback.dataDir()` 抛
  // "Binding has not yet been initialized." ⇒ 首帧前读设置整个跳过)。
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  // 首帧之前先读设置(缓存审计 P2「启动首帧主题闪」): 以前 `AppSettings.load` 在首页
  // initState 的 bootstrap 里, 于是**第一帧必定用默认主题/档位**渲染, 落盘设置一到位再翻一次
  // —— 深色/OLED/自定义主题的用户每次启动都会看到一下浅色。
  //
  // 这里只取**目录路径**(Android = 平台通道给的私有目录; 桌面 = Rust 的默认目录计算),
  // 不碰 `rust.init()`(那是 keystore 恢复 + `Core::open`, 挪到首帧前会拖慢冷启动)。
  // bootstrap 之后仍会按 `init()` 返回的 `info.dataDir` 再 `load` 一次: 文件很小,
  // 那次是"以生效中的目录为准"的自校验(两个目录不一致时不会留下错的那份设置)。
  try {
    final dir = await Playback().dataDir() ?? await rust.dataDirDefault();
    await AppSettings.instance.load(dir);
    debugPrint(
      '[NCM-BOOT] 首帧前已读设置(loaded=${AppSettings.instance.loaded}, '
      'themeMode=${AppSettings.instance.themeMode.name}, dir=$dir)',
    );
  } catch (e) {
    // 读设置失败不该拦住启动: bootstrap 会按 init 的真实目录再试一次
    debugPrint('[NCM-BOOT] 首帧前读设置失败(交给 bootstrap 重试): $e');
  }
  runApp(const MiniNcmApp());
}
