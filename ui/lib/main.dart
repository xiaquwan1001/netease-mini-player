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

import 'src/app_shell.dart';
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
// 逐字歌词来源解析与打分(与 Rust 同口径镜像, 见文件头注释)。
export 'src/lyric_source.dart'
    show
        LyricSourceLoaders,
        ResolvedLyric,
        WordLyricScore,
        chooseWordSource,
        lyricSourceLabel,
        kYrcWordCoverageThreshold,
        resolveLyricSource,
        scoreWordLyric,
        yrcWordGoodEnough;
// 通知栏: 播放顺序轮转 + 自定义按钮图标。
export 'src/notification_mode.dart'
    show nextNotificationMode, notificationModeIcon;

Future<void> main() async {
  await RustLib.init();
  runApp(const MiniNcmApp());
}
