import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'src/marquee_text.dart';

import 'package:flutter/services.dart';

import 'src/album_preview.dart';
import 'src/cover_backdrop.dart';
import 'src/cover_palette.dart';
import 'src/sheet_header.dart';
import 'src/similar_sheet.dart';
import 'src/user_list_page.dart';
import 'src/app_settings.dart';
import 'src/audio_tuning.dart';
import 'src/artist_nav.dart';
import 'src/artist_page.dart';
import 'src/auth.dart';
import 'src/cover_art.dart';
import 'src/daily_cache.dart';
import 'src/detail_page.dart';
import 'src/discover.dart';
import 'src/feed_view.dart';
import 'src/format.dart' show formatCountMagnitude;
import 'src/lyric.dart';
import 'src/word_lyric_view.dart';
import 'src/layout.dart' show rowExtentFor;
import 'src/library_view.dart';
import 'src/login_sheet.dart';
import 'src/medal_wall.dart';
import 'src/messages_page.dart';
import 'src/new_release_page.dart';
import 'src/mine_view.dart';
import 'src/net_retry.dart';
import 'src/play_queue_sheet.dart';
import 'src/keystore.dart';
import 'src/player_bar.dart';
import 'src/playback.dart';
import 'src/playback_policy.dart';
import 'src/playback_state.dart';
import 'src/queue.dart';
import 'src/platform.dart';
import 'src/recommend_view.dart';
import 'src/search_landing.dart';
import 'src/search_exact_bar.dart';
import 'src/search_loading.dart';
import 'src/search_results.dart';
import 'src/search_suggest.dart';
import 'src/settings_account_page.dart';
import 'src/settings_view.dart';
import 'src/update_checker.dart';
import 'src/update_dialog.dart';
import 'src/user_nav.dart';
import 'src/song_actions.dart';
import 'src/song_share.dart';
import 'src/song_tile.dart';
import 'src/song_wiki.dart';
import 'src/toast.dart' show showToast;
import 'src/theme.dart';
import 'src/vip_page.dart';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart' show Uint64List;

import 'src/rust/api.dart' as rust;
import 'src/rust/frb_generated.dart';

/// ---------------- B13: 逐字歌词三来源解析(yrc -> AMLL TTML -> 行级) ----------------

/// 三个来源的 loader 抽象: 生产环境包 rust.* 调用, 单测注入假实现(不联网)。
class LyricSourceLoaders {
  final Future<rust.WordLyricDto?> Function(BigInt trackId) yrc;
  final Future<rust.WordLyricDto?> Function(BigInt trackId) ttml;
  final Future<List<rust.LyricLineDto>?> Function(BigInt trackId) lineLevel;
  const LyricSourceLoaders({
    required this.yrc,
    required this.ttml,
    required this.lineLevel,
  });
}

/// 解析结果: word = 逐字数据(来源 yrc/ttml), line = 行级兜底, source 给小字标注,
/// reason 为 auto 择优理由(仅两来源比较后才有, 标注显示"择优: ...")。
class ResolvedLyric {
  final rust.WordLyricDto? word;
  final List<rust.LyricLineDto>? line;
  final String source;
  final String? reason;
  const ResolvedLyric.word_(this.word, {this.reason})
    : line = null,
      source = 'yrc';
  const ResolvedLyric.ttml_(this.word, {this.reason})
    : line = null,
      source = 'ttml';
  const ResolvedLyric.line_(this.line)
    : word = null,
      source = 'line',
      reason = null;
}

/// yrc 逐字行覆盖率: 有词级时间(end > start)的行占比. 与 Rust
/// ncm_service::ttml_source::yrc_word_coverage 同口径, 阈值 0.6(六成行是逐字才算合格)。
const double kYrcWordCoverageThreshold = 0.6;

bool yrcWordGoodEnough(rust.WordLyricDto? wl) {
  if (wl == null || wl.lines.isEmpty || !wl.hasWordTiming) return false;
  final covered = wl.lines
      .where((l) => l.words.any((w) => w.endMs > w.startMs))
      .length;
  return covered / wl.lines.length >= kYrcWordCoverageThreshold;
}

/// ---------------- C2: 打分择优(与 Rust ncm_service::ttml_source 同口径的 Dart 镜像) ----------------

/// auto 模式 yrc 得分 >= 此值即直接用, 不再探测 TTML(省一次网络)。
const double kAutoSkipTtmlScore = 0.9;

/// 打分权重: 覆盖率/时间单调/首字贴行首/每行粒度/与行级 LRC 一致性(和为 1)。
const List<double> kScoreWeights = [0.3, 0.2, 0.15, 0.15, 0.2];
const int _kMonotonicToleranceMs = 50;
const int _kFirstWordToleranceMs = 80;
const int _kLineConsistencyMs = 250;

/// 打分分项与总分(全部 0..1)。与 Rust score_word_lyric 保持同一口径。
class WordLyricScore {
  final double coverage, monotonic, firstWord, spans, consistency, score;
  const WordLyricScore(
    this.coverage,
    this.monotonic,
    this.firstWord,
    this.spans,
    this.consistency,
    this.score,
  );
}

/// 逐字歌词质量打分(纯函数). lineStarts 为行级 LRC 各行起始 ms, 无参照时一致性记 1(中性)。
WordLyricScore scoreWordLyric(rust.WordLyricDto? wl, {List<int>? lineStarts}) {
  if (wl == null || wl.lines.isEmpty) {
    return const WordLyricScore(0, 0, 0, 0, 0, 0);
  }
  final timed = wl.lines
      .where((l) => l.words.any((w) => w.endMs > w.startMs))
      .toList();
  final coverage = timed.length / wl.lines.length;
  double monotonicOf() {
    if (timed.length <= 1) return 1.0;
    var ok = 0;
    for (var i = 1; i < timed.length; i++) {
      if (timed[i].startMs >= timed[i - 1].startMs - _kMonotonicToleranceMs) {
        ok++;
      }
    }
    return ok / (timed.length - 1);
  }

  final monotonic = monotonicOf();
  final firstWord = timed.isEmpty
      ? 0.0
      : timed
                .where(
                  (l) =>
                      (l.words.first.startMs - l.startMs).abs() <=
                      _kFirstWordToleranceMs,
                )
                .length /
            timed.length;
  final spans = timed.isEmpty
      ? 0.0
      : (timed.map((l) => l.words.length).reduce((a, b) => a + b) /
                timed.length /
                2.0)
            .clamp(0.0, 1.0);
  final consistency = (lineStarts == null || lineStarts.isEmpty)
      ? 1.0
      : wl.lines
                .where(
                  (l) => lineStarts.any(
                    (s) => (l.startMs - s).abs() < _kLineConsistencyMs,
                  ),
                )
                .length /
            wl.lines.length;
  final w = kScoreWeights;
  final score =
      w[0] * coverage +
      w[1] * monotonic +
      w[2] * firstWord +
      w[3] * spans +
      w[4] * consistency;
  return WordLyricScore(
    coverage,
    monotonic,
    firstWord,
    spans,
    consistency,
    score,
  );
}

/// auto 择优纯函数: 两来源都在时选高分者并给出短理由; 只有一方直接选它(理由 null)。
({String? source, String? reason}) chooseWordSource(
  rust.WordLyricDto? yrc,
  rust.WordLyricDto? ttml, {
  List<int>? lineStarts,
}) {
  final hasY = yrc != null && yrc.lines.isNotEmpty;
  final hasT = ttml != null && ttml.lines.isNotEmpty;
  if (!hasY && !hasT) return (source: null, reason: null);
  if (hasY && !hasT) return (source: 'yrc', reason: null);
  if (!hasY && hasT) return (source: 'ttml', reason: null);
  final sy = scoreWordLyric(yrc, lineStarts: lineStarts);
  final st = scoreWordLyric(ttml, lineStarts: lineStarts);
  if (sy.score >= st.score) return (source: 'yrc', reason: 'yrc 质量更优');
  final String reason;
  if (sy.monotonic < 0.5) {
    reason = 'yrc 时间错乱';
  } else if (sy.coverage < kYrcWordCoverageThreshold) {
    reason = 'yrc 覆盖低';
  } else if (sy.firstWord < 0.5) {
    reason = 'yrc 首字偏移';
  } else if (sy.spans < st.spans) {
    reason = 'yrc 粒度差';
  } else {
    reason = 'TTML 得分更高';
  }
  return (source: 'ttml', reason: reason);
}

/// 来源小字标注文案(纯函数, 单测覆盖)。短文案: "逐字歌词 · AMLL(择优: yrc 时间错乱)"。
String lyricSourceLabel(String? source, String? reason) {
  if (source == null) return '';
  final base = switch (source) {
    'yrc' => '逐字歌词 · 网易云',
    'ttml' => '逐字歌词 · AMLL',
    _ => '逐行歌词',
  };
  if (reason == null || source == 'line') return base;
  return '$base(择优: $reason)';
}

/// 三来源决策(按偏好 auto/netease/amll). 任一来源抛错都当作"该来源没有",
/// 继续回退, 绝不上抛。
Future<ResolvedLyric?> resolveLyricSource(
  BigInt trackId,
  LyricSourceLoaders loaders, {
  String preference = 'auto',
}) async {
  Future<rust.WordLyricDto?> loadYrc() async {
    try {
      return await loaders.yrc(trackId);
    } catch (_) {
      return null;
    }
  }

  Future<rust.WordLyricDto?> loadTtml() async {
    try {
      final t = await loaders.ttml(trackId);
      return (t == null || t.lines.isEmpty) ? null : t;
    } catch (_) {
      return null;
    }
  }

  // amll: TTML 优先, 失败再 yrc
  if (preference == 'amll') {
    final ttml = await loadTtml();
    if (ttml != null) return ResolvedLyric.ttml_(ttml);
    final yrc = await loadYrc();
    if (yrc != null && yrc.lines.isNotEmpty) return ResolvedLyric.word_(yrc);
    return _lineLevel(trackId, loaders);
  }

  final yrc = await loadYrc();
  // netease: 旧口径(0.6 覆盖率阈值), 够好就直接用
  if (preference == 'netease') {
    if (yrcWordGoodEnough(yrc)) return ResolvedLyric.word_(yrc);
    final ttml = await loadTtml();
    if (ttml != null) return ResolvedLyric.ttml_(ttml);
    if (yrc != null && yrc.lines.isNotEmpty) return ResolvedLyric.word_(yrc);
    return _lineLevel(trackId, loaders);
  }

  // auto: 打分择优; yrc 得分已很高就不必请求 TTML(避免无谓网络)
  if (yrc != null && yrc.lines.isNotEmpty) {
    final sy = scoreWordLyric(yrc);
    if (sy.score >= kAutoSkipTtmlScore) return ResolvedLyric.word_(yrc);
  }
  final ttml = await loadTtml();
  if (yrc != null || ttml != null) {
    List<int>? lineStarts;
    // 得分接近时才取行级 LRC 起始时间做一致性加分(可注入 loader, 不额外打无谓网络)
    if (yrc != null && ttml != null) {
      final sy = scoreWordLyric(yrc);
      final st = scoreWordLyric(ttml);
      if ((sy.score - st.score).abs() < 0.15) {
        try {
          final line = await loaders.lineLevel(trackId);
          lineStarts = line?.map((l) => l.timeMs.toInt()).toList();
        } catch (_) {}
      }
    }
    final choice = chooseWordSource(yrc, ttml, lineStarts: lineStarts);
    if (choice.source == 'ttml' && ttml != null) {
      return ResolvedLyric.ttml_(ttml, reason: choice.reason);
    }
    if (choice.source == 'yrc' && yrc != null && yrc.lines.isNotEmpty) {
      return ResolvedLyric.word_(yrc, reason: choice.reason);
    }
  }
  // yrc 差但非空且 TTML 没有: 仍比行级好
  if (yrc != null && yrc.lines.isNotEmpty) return ResolvedLyric.word_(yrc);
  return _lineLevel(trackId, loaders);
}

Future<ResolvedLyric?> _lineLevel(
  BigInt trackId,
  LyricSourceLoaders loaders,
) async {
  try {
    final line = await loaders.lineLevel(trackId);
    if (line != null && line.isNotEmpty) return ResolvedLyric.line_(line);
  } catch (_) {}
  return null;
}

Future<void> main() async {
  await RustLib.init();
  runApp(const MiniNcmApp());
}

/// 通知栏「播放顺序」按钮的轮转顺序(列表循环→单曲循环→顺序播放→随机播放→心动模式).
/// 心动模式不是 PlayMode, 用返回 null 表示「下一步应进入心动模式」. 纯函数, 便于单测.
PlayMode? nextNotificationMode(PlayMode mode) {
  const order = [
    PlayMode.repeatAll,
    PlayMode.repeatOne,
    PlayMode.sequence,
    PlayMode.shuffle,
  ];
  final i = order.indexOf(mode);
  return i + 1 < order.length ? order[i + 1] : null;
}

/// 通知栏模式按钮的图标名(与 Kotlin 侧 modeIconRes 对齐); 心动模式优先用 heart 表达.
String notificationModeIcon(PlayMode mode, {required bool heartActive}) {
  if (heartActive) return 'heart';
  return switch (mode) {
    PlayMode.repeatAll => 'repeat',
    PlayMode.repeatOne => 'repeatOne',
    PlayMode.sequence => 'sequence',
    PlayMode.shuffle => 'shuffle',
  };
}

/// 全局动作回调宿主: MaterialApp.builder 里包一层 AppActions,
/// 这样搜索结果/详情页/底部面板等所有路由里的 "..." 菜单都能拿到同一套回调。
final ValueNotifier<SongActionHost?> _actionsHost =
    ValueNotifier<SongActionHost?>(null);

/// 根导航栈里"全屏页"的层数(弹层/对话框不算一层): 1 = 只有首页.
///
/// 底部 tab 属于首页, 有全屏页压上来时让位; 若按 [ModalRoute.isCurrent] 判断,
/// 弹一个底部面板(PopupRoute)也会让底部导航消失, 所以这里只数非弹层路由。
///
/// 初值 0 而不是 1: 首页这条路由本身也会走 didPush(变成 1); 而手工 pump HomePage
/// 的单测里没有观察者, 值停在 0 —— 两者都满足 "<= 1 就是首页在栈顶"。
final ValueNotifier<int> _pageDepth = ValueNotifier<int>(0);

/// NavigatorObserver: 维护 [_pageDepth](栈里非弹层路由的层数).
class _PageDepthObserver extends NavigatorObserver {
  static void _up() {
    if (_pageDepth.value < 1) {
      _pageDepth.value = 1;
    } else {
      _pageDepth.value = _pageDepth.value + 1;
    }
  }

  static void _down() {
    _pageDepth.value = _pageDepth.value > 1 ? _pageDepth.value - 1 : 1;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _up();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _down();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) return;
    _down();
  }
}

/// 常驻底部条(播放条 + 首页底部导航)的投递槽位。
///
/// 播放条原先在 HomePage.bottomNavigationBar 里, 只有首页看得到; 二级页(日推"全部"、
/// 歌单广场、风格详情、搜索页…)一压上来就没了。这里改由根布局 [PlayerBarHost] 渲染,
/// 位置在 Navigator **之下**(Column 的兄弟, 不是覆盖层): 二级页自己的底部面板/滚动区
/// 都落在它上方, 不会被它压住。唯一让位时机是键盘弹出 —— 那时它本来就被键盘挡住,
/// 留着只会白占内容高度。
final ValueNotifier<Widget?> playerBarSlot = ValueNotifier<Widget?>(null);

/// 常驻播放条的数据快照槽位: HomePage 每帧投一份 [PlayerBarData](帧后),
/// 与上一份相等时 ValueNotifier 不通知 → 播放条只在数据真变时才重建。
final ValueNotifier<PlayerBarData?> playerBarData =
    ValueNotifier<PlayerBarData?>(null);

/// 常驻播放条的回调集合槽位: HomePage 在 initState 里建一次, 之后不再变。
final ValueNotifier<PlayerBarActions?> playerBarActions =
    ValueNotifier<PlayerBarActions?>(null);

/// 投递底部条(每次 HomePage 构建投一次, 内容变了才通知)。
///
/// 必须在帧后投递: 槽位的监听者是 Navigator 的祖先, 在 HomePage.build 里同步写
/// ValueNotifier 等于在 build 阶段 markNeedsBuild 祖先 → "setState() called during build"。
void _publishBottomBar(Widget? bar) {
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => playerBarSlot.value = bar,
  );
}

/// 应用外壳: Navigator 与常驻底部条一起放进一个全屏 Overlay。
///
/// 为什么要有这层 Overlay: 播放条里的 Slider/Tooltip 用 OverlayPortal 画气泡,
/// 必须有 Overlay 祖先; 而它又必须活在 Navigator 之外才能穿透二级路由。
/// 条目内容通过 [_content] 更新(Overlay.initialEntries 只在首次生效, 每次塞新
/// Widget 会卡在旧的 Navigator 上, 主题/字号设置改了不生效)。
class PlayerBarHost extends StatefulWidget {
  const PlayerBarHost({super.key, required this.content});

  final Widget content;

  @override
  State<PlayerBarHost> createState() => _PlayerBarHostState();
}

class _PlayerBarHostState extends State<PlayerBarHost> {
  late final ValueNotifier<Widget> _content = ValueNotifier<Widget>(
    widget.content,
  );
  late final OverlayEntry _entry = OverlayEntry(
    builder: (_) => _PlayerBarChrome(content: _content),
  );

  @override
  void didUpdateWidget(covariant PlayerBarHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 监听者在条目内部(后代), 不是祖先, 在 build 之外通知更稳
    _content.value = widget.content;
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: [_entry]);
}

class _PlayerBarChrome extends StatelessWidget {
  const _PlayerBarChrome({required this.content});

  final ValueListenable<Widget> content;

  @override
  Widget build(BuildContext context) {
    // 键盘弹出时底部条不占位: 反正会被键盘挡住, 留着只会把内容区白压一条
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    return ValueListenableBuilder<PlayerBarActions?>(
      valueListenable: playerBarActions,
      builder: (context, actions, _) => ValueListenableBuilder<PlayerBarData?>(
        valueListenable: playerBarData,
        builder: (context, data, _) => ValueListenableBuilder<Widget?>(
          valueListenable: playerBarSlot,
          builder: (context, navBar, _) => ValueListenableBuilder<Widget>(
            valueListenable: content,
            builder: (context, body, _) {
              final bar = (data == null || actions == null || keyboardUp)
                  ? null
                  // 没有底部导航时播放条自己吃掉系统手势区
                  : MiniPlayerBar(
                      data: data,
                      actions: actions,
                      absorbBottomInset: navBar == null,
                    );
              // 底部条与底部导航都挂在 Navigator 之外(根布局), 看到的是根 MediaQuery
              // ⇒ padding.top 仍是状态栏高度。NavigationBar 内部的 SafeArea 没关 top
              // (它默认同时吃 top), 不剥掉就会在导航栏顶部多出一条状态栏高的空白,
              // 表现为"播放条与底部导航之间有一段空", 同时整块底栏变高挤压内容区。
              //
              // 2026-11-13: 底部手势区原样(~24dp)全部被导航栏吃掉, 视觉上底部留白过大
              // (用户反馈"略微下移底部导航栏, 减少到底部的空白")。这里把 bottom inset
              // 夹到 8dp(仍高于手势条本体, 不挡点击), 导航栏整体下移约 16dp。
              final mq = MediaQuery.of(context);
              final nav = navBar == null
                  ? null
                  : MediaQuery(
                      data: mq.copyWith(
                        padding: mq.padding.copyWith(
                          top: 0,
                          bottom: mq.padding.bottom.clamp(0.0, 8.0),
                        ),
                        viewPadding: mq.viewPadding.copyWith(
                          top: 0,
                          bottom: mq.viewPadding.bottom.clamp(0.0, 8.0),
                        ),
                      ),
                      child: navBar,
                    );
              return Column(
                children: [
                  Expanded(child: body),
                  ?bar,
                  ?nav,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class MiniNcmApp extends StatelessWidget {
  const MiniNcmApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: AppSettings.instance,
      builder: (context, _) {
        final settings = AppSettings.instance;
        return MaterialApp(
          title: '轻音 MiniNCM',
          // 桌面版 debug 构建的 DEBUG 斜标会压住 AppBar 右上角的歌单/账号按钮
          debugShowCheckedModeBanner: false,
          // 视觉风格(主题色): 同一色板同时决定浅色/深色两套配色的 seed
          theme: buildLightTheme(accent: settings.accent),
          // R6: 深色 + OLED 开关 ⇒ 纯黑基底(见 src/theme.dart)
          darkTheme: buildDarkTheme(
            oled: settings.oledDark,
            accent: settings.accent,
          ),
          themeMode: settings.themeMode,
          builder: (context, child) => MediaQuery(
            data: scaledMediaQuery(context, settings.textScale),
            // 动作回调挂在 Navigator 之上, pushed route 也能取到
            child: ValueListenableBuilder<SongActionHost?>(
              valueListenable: _actionsHost,
              builder: (_, host, inner) =>
                  host == null ? inner! : AppActions(host: host, child: inner!),
              child: PlayerBarHost(content: child ?? const SizedBox.shrink()),
            ),
          ),
          // 只用来数"有没有全屏页压在首页上"(决定底部 tab 是否让位)
          navigatorObservers: [_PageDepthObserver()],
          home: const HomePage(),
        );
      },
    );
  }
}

/// 根页面的返回键优先级, 从高到低:
/// 歌词展开 → 收起歌词; 非首 tab → 回搜索 tab; 歌单浏览态 → 退出浏览;
/// 都没有(栈底 + 无二级态) → 交还系统, 由系统退出 App.
///
/// 纯函数, 便于单测(返回键的分支比 UI 更容易出错).
enum HomeBackAction { collapseLyrics, resetTab, closeLibrary, exitApp }

HomeBackAction resolveHomeBackAction({
  required bool showLyrics,
  required int tab,
  required bool libraryOpen,
}) {
  if (showLyrics) return HomeBackAction.collapseLyrics;
  if (tab != 0) return HomeBackAction.resetTab;
  if (libraryOpen) return HomeBackAction.closeLibrary;
  return HomeBackAction.exitApp;
}

/// 把 [HomeBackAction] 接到系统返回键(Android 手势/返回键, 桌面 Esc)上.
///
/// 只有"栈底且无二级态"时 canPop=true 让系统退出, 其余一律拦下来先退一层;
/// 否则用户在歌词页/推荐页按返回会直接退出 App(审查 P0-7.1).
class HomeBackGuard extends StatelessWidget {
  const HomeBackGuard({
    super.key,
    required this.action,
    required this.onBack,
    required this.child,
  });

  final HomeBackAction action;
  final VoidCallback onBack;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: action == HomeBackAction.exitApp,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        onBack();
      },
      child: child,
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _controller = TextEditingController();
  final _playback = Playback();
  final _auth = Auth();
  final _queue = PlayQueue<rust.SongDto>();
  final _lyricScroll = ScrollController();
  rust.InitInfo? _info;
  rust.SearchBundleDto? _bundle;
  PlayerView? _player;
  String? _error;

  /// 出错时可以一键重试的动作(搜索/打开歌单这类幂等操作)
  Future<void> Function()? _retryLast;
  bool _busy = false;
  Timer? _ticker;

  /// 用户主动停止后不再自动续播
  bool _userStopped = false;

  /// 启动时从 play_state.json 恢复了上次的队列/曲目(尚未真正加载到播放器)。
  /// 这段时间里轮询到"播放器空"不能把恢复出来的播放条清掉; 用户按播放才真正续播。
  bool _restoredFromDisk = false;

  /// 恢复出来的续播位置(毫秒), 用户按播放时 seek 到这里
  int _restoredResumeMs = 0;

  /// 上次落盘播放现场的时间(节流: 每 5s 最多一次, 避免每 500ms 轮询都写文件)
  DateTime? _lastStateSave;

  /// 拖动进度条时的临时值(避免每帧都 seek); _dragMax 在拖动开始时冻结,
  /// 否则自动续播换曲会让滑杆量程突跳, 把新曲目 seek 到末尾。
  double? _dragMs;
  double? _dragMax;

  /// 续播临界区: 防止一次结束被处理两遍(轮询 500ms + 异步取链)
  bool _advancing = false;

  // ---- 歌词 ----
  /// 歌词行高: 基准 56dp, 随系统字号等比放大。
  /// 固定 56dp 在 textScale≥1.4 时装不下「18sp 主词 + 12sp 翻译」两行,
  /// 行内容被 ListView 的 itemExtent 从下方裁掉(用户反馈"顶部歌词只显示上半段").
  double get _lyricItemExtent => rowExtentFor(context);

  List<ParsedLyricLine> _lyricLines = const [];
  List<BigInt> _lyricTimes = const [];

  /// 纯文本歌词兜底(无时间轴): 逐行接口失败/返回空时用 [parseLrc] 从原始 LRC 里取。
  List<String>? _lyricPlain;
  BigInt? _lyricTrackId;
  String? _lyricError;

  // 歌词来源("yrc"/"ttml"/"line")与择优理由不再上屏(左下角那条像水印的
  // 小字已按用户要求去掉), 决策逻辑与文案生成仍留在 lyricSourceLabel / scoreWordLyric.
  int _lyricIndex = -1;
  bool _showLyrics = false;

  /// 歌词是否跟随播放自动滚动: 用户手动滑歌词时置 false, 点"定位"再置回 true
  bool _autoFollowLyric = true;

  /// 详情页歌词多选: 长按进入, 点行加/减选, 选中后右上角变成分享/取消
  final Set<int> _selectedLyricLines = <int>{};

  /// 逐字(karaoke)歌词数据; 有则优先用 [WordLyricView], 无则回落行级/纯文本链。
  List<WordLyricLineData> _wordLines = const [];

  /// 播放位置(毫秒)注入给 [WordLyricView]: 刷新只重建当前行, 不整页 setState。
  final ValueNotifier<int> _wordPositionMs = ValueNotifier<int>(0);

  /// 播放中标志注入给 [WordLyricView]/[KaraokeLine]: 播放时才在行内插值到 60fps,
  /// 暂停/default 场景不排帧(省电, 也让 pumpAndSettle 能收敛)。
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);

  /// 展开歌词时的高频位置刷新(~120ms); 收起必须停掉, 避免后台耗电。
  Timer? _lyricTicker;

  /// "我喜欢的音乐"里的曲目 id: 红心状态的唯一真相
  Set<BigInt> _liked = <BigInt>{};

  /// 歌单浏览态: 非空时列表显示这个歌单而不是搜索结果
  List<rust.SongDto> _library = const [];
  String? _libraryTitle;

  /// 当前浏览的歌单 id(心动模式要用 playlistId; 搜索态为 null)
  BigInt? _libraryPlaylistId;

  /// 当前播放队列的来源歌单 id(详情页"定位正在播放"用;
  /// 搜索/心动模式/推荐流等非歌单队列为 null)
  BigInt? _queuePlaylistId;

  /// "我喜欢的音乐"这个歌单的 id(懒解析: 从"我的"页点播时要用它标记队列来源)
  BigInt? _likedPlaylistId;

  /// 底部导航: 0 搜索 / 1 推荐 / 2 关注 / 3 我的 / 4 设置
  int _tab = 0;

  /// 已经打开过的 tab: 只有访问过的页面才进 IndexedStack(惰性构建),
  /// 之后一直保留 State —— 否则每次切 tab 都销毁重建子树,
  /// 图片 Widget 重新解析, 占位符会高频闪烁, 列表滚动位置也会丢
  final Set<int> _tabVisited = <int>{0};

  /// 搜索请求代次: 取消/重新搜索后旧请求的结果直接丢弃
  int _searchToken = 0;

  // ---- 搜索建议 / 历史 ----
  final _searchFocus = FocusNode();
  Timer? _suggestDebounce;
  List<rust.SuggestItem> _suggestions = const [];

  /// 精确实体命中(search_multimatch; orders 为空 = 无命中)
  rust.SearchExact? _exact;

  /// 纯关键词联想(mobile search_suggest; 卡片/实体都空时的兜底)
  List<String> _keywordSuggestions = const [];
  List<String> _searchHistory = const [];

  // ---- 搜索落地页(热词/推荐词) ----
  List<rust.HotSearchTerm> _hotTerms = const [];

  /// "猜你想搜": keyword 是真正要搜的词, reason 是官方给的推荐理由(只展示)
  String? _recommendedKeyword;
  String? _recommendedReason;
  bool _hotLoading = false;
  String? _hotError;

  rust.SongDto? get _current => _queue.current;

  /// 当前列表的原始曲目(歌单浏览优先)
  List<rust.SongDto> get _sourceSongs => _libraryTitle != null
      ? _library
      : (_bundle?.songs ?? const <rust.SongDto>[]);

  /// 真正要显示/入队的曲目: 无版权且没收藏的直接不显示(与官方一致)
  List<rust.SongDto> get _visibleSongs => visibleSongs(_sourceSongs, _liked);

  /// 被隐藏的无版权曲目数量(列表顶部提示用)
  int get _hiddenUnplayable => hiddenUnplayableCount(_sourceSongs, _liked);

  /// 播放条回调集合: 建一次跨帧复用(回调内部读 State 字段, 不持有任何快照)。
  late final PlayerBarActions _playerBarActions;

  /// 已经弹过更新提示的版本 tag(同一次运行只弹一次, 避免重复打扰)
  String? _promptedUpdateTag;

  @override
  void initState() {
    super.initState();
    _playerBarActions = PlayerBarActions(
      onSeekStart: (v) => setState(() {
        _dragMax = (_player?.durationMs ?? BigInt.zero).toDouble();
        _dragMs = v;
      }),
      onSeekChanging: (v) => setState(() => _dragMs = v),
      onSeekEnd: _seekTo,
      // 首页被压住时先回首页再展开歌词: 否则切换的是看不见的那一页,
      // 用户只会觉得"点了没反应"
      onToggleLyrics: () {
        if (_pageDepth.value > 1) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        _toggleLyrics();
      },
      // 播放条封面点击 = 进入播放详情(不是专辑预览, 用户要求)
      onOpenDetail: () {
        if (_pageDepth.value > 1) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
        if (!_showLyrics) _toggleLyrics();
      },
      onToggleLike: _toggleLike,
      onToggle: _toggle,
      onPrevious: _previous,
      onNext: _next,
      onCycleMode: _cycleMode,
      onOpenQueue: _openQueueSheet,
    );
    // 播放条回调槽位只赋这一次(同一实例, 之后不再变)
    WidgetsBinding.instance.addPostFrameCallback(
      (_) =>
          playerBarActions.value = playerBarActions.value ?? _playerBarActions,
    );
    // 通知栏/耳机键的上一首·下一首 → Dart 队列
    // onEnded: 原生播放器 STATE_ENDED 的即时通知(不靠 500ms 轮询) —— 自动续播
    // 的间隙主要就是"轮询发现播完 + 重新取链"堆出来的
    Playback.setSkipHandlers(
      onNext: _next,
      onPrevious: _previous,
      onEnded: _onNativeTrackEnded,
    );
    // 通知栏自定义按钮(喜欢/播放顺序): 原生只发意图, 状态与副作用都在 Dart
    Playback.setActionHandlers(
      onToggleLike: _toggleLike,
      onCycleMode: _cycleModeFromNotification,
    );
    // R2/R5/R7: 设置里的播放参数变化时同步给 Rust 播放器
    AppSettings.instance.addListener(_onAudioSettingsChanged);
    // "..." 菜单的动作宿主在 Navigator 之上, 先放一份(登录态变化时再刷新)
    _actionsHost.value = _buildActionsHost();
    _searchFocus.addListener(_onSearchFocusChanged);
    // 头像点击进入用户主页时, 主页里点歌仍要能播(共享同一份播放回调)
    UserNav.onPlaySongs = _playSongsList;
    // 艺人主页同理(关注流里的艺人头像 → 艺人主页, 与搜索进的是同一份页面)
    ArtistNav.onPlaySongs = _playSongsList;
    ArtistNav.onOpenAlbum = (albumId, albumName, coverUrl) => showAlbumPreview(
      context,
      albumId: albumId,
      albumName: albumName,
      coverUrl: coverUrl,
      onPlay: _playSongsList,
    );
    // 启动自动检查发现新版本 -> 程序内弹窗(设置页手动检查走自己的弹窗)
    UpdateCheckHost.pendingPrompt.addListener(_onUpdatePrompt);
    // 二级页压上来/退回时要重算底部条(tab 让位、播放条自己吸收安全区)
    _pageDepth.addListener(_onPageDepthChanged);
    _bootstrap();
    _ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollPlayer(),
    );
  }

  @override
  void dispose() {
    AppSettings.instance.removeListener(_onAudioSettingsChanged);
    _ticker?.cancel();
    _suggestDebounce?.cancel();
    _searchFocus.removeListener(_onSearchFocusChanged);
    UpdateCheckHost.pendingPrompt.removeListener(_onUpdatePrompt);
    _pageDepth.removeListener(_onPageDepthChanged);
    _searchFocus.dispose();
    _lyricTicker?.cancel();
    _lyricScroll.dispose();
    _wordPositionMs.dispose();
    _playing.dispose();
    super.dispose();
  }

  void _onPageDepthChanged() {
    if (mounted) setState(() {});
  }

  /// 启动自动检查发现新版本时的弹窗(每天/每周/每月由 AppSettings 决定)。
  void _onUpdatePrompt() {
    final info = UpdateCheckHost.pendingPrompt.value;
    if (info == null || !info.isNewer) return;
    if (info.latest == _promptedUpdateTag) return;
    _promptedUpdateTag = info.latest;
    // 立即清掉, 避免同一次通知重入; 红点仍由 pendingUpdate 维护。
    UpdateCheckHost.pendingPrompt.value = null;
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showUpdateDialog(context, info);
    });
  }

  Future<void> _bootstrap() async {
    try {
      final dir = await _playback.dataDir();
      // Android Keystore 凭据桥: 先 restore(幂等, 非 Android/不可用则跳过)再开 Core,
      // 否则 Core::open 选不到后端(见 docs/android-keystore-wiring-design.md).
      await credentialSync.ensureRestored();
      final info = await rust.init(dataDir: dir);
      await AppSettings.instance.load(info.dataDir);
      // 登录期可能产生 pending, 启动点落一次 Keystore
      unawaited(credentialSync.drainPending());
      // 启动时把已保存的播放参数与缓存上限应用一次(默认值 = 不改变现状)
      // 首帧后 3s 后台静默检查更新(节流/开关在 update_checker 内, 失败静默)
      unawaited(runStartupUpdateCheck(AppSettings.instance));
      unawaited(applyAudioTuning());
      unawaited(enforceCacheLimit());
      if (!mounted) return;
      setState(() => _info = info);
      _actionsHost.value = _buildActionsHost();
      // 状态记忆: 恢复上次退出时的队列与曲目(只恢复现场, 不自动出声)
      unawaited(_restorePlayback(info.dataDir));
      // 本地历史和热词都依赖 init() 建立的 Core, 必须等初始化完成再拉
      unawaited(_loadSearchHistory());
      unawaited(_loadSearchLanding());
      // 已登录就把账号记进账号簿(老版本登录过的账号也能被记住)
      if (info.loggedIn) {
        unawaited(_syncAccount());
        unawaited(_loadLiked());
        unawaited(_resolveLikedPlaylistId());
      }
    } catch (e) {
      setState(() => _error = friendlyError(e));
    }
  }

  /// 播放参数变化时才真的调 FFI(设置页里每拖一格 Slider 都会 notifyListeners)
  AudioTuningRequest? _lastTuning;
  int? _lastCacheLimitMb;
  bool? _lastLoudnessNormalize;
  double? _lastLoudnessTarget;

  /// 已经为哪首曲目应用过响度增益(避免每 500ms 轮询都重算)
  int? _loudnessAppliedTrackId;

  /// 最近取到的直链(曲目 id -> url): Android 的响度测量要靠它去 SimpleCache 里找缓存文件
  final Map<int, String> _streamUrlByTrack = <int, String>{};

  /// 上一次"补测响度"的时间(Android 的缓存文件要整首存完才能测, 所以播放中隔一会儿重试)
  DateTime? _lastLoudnessRetry;

  /// 状态记忆: 恢复上次退出时的播放现场(队列 + 当前曲 + 位置)。
  ///
  /// 只恢复"看起来的样子", 不自动播放 —— 用户可能只是在后台/耳机里退出的,
  /// 重开 App 吓一跳不合适。点播放才真正取链, 并从保存的位置续播。
  Future<void> _restorePlayback(String dataDir) async {
    if (dataDir.isEmpty || _queue.items.isNotEmpty) return;
    final saved = await PlaybackStateStore(dataDir).load();
    if (saved == null || saved.songs.isEmpty || !mounted) return;
    if (_queue.items.isNotEmpty) return; // 期间用户已经点歌了, 不覆盖
    setState(() {
      _queue.setAll(saved.songs, startAt: saved.index);
      _queue.mode = saved.mode;
      _library = saved.songs;
      _libraryTitle = saved.libraryTitle ?? '正在播放';
      _libraryPlaylistId = null;
      _queuePlaylistId = null;
      final song = saved.current;
      _player = PlayerView(
        trackId: song.id,
        playing: false,
        positionMs: BigInt.from(saved.positionMs),
        durationMs: song.durationMs,
        volume: 1.0,
      );
      _restoredFromDisk = true;
      _restoredResumeMs = saved.positionMs;
    });
  }

  /// 状态记忆: 落盘当前现场(节流 5s; [force] 用于换曲/暂停等必须立刻记住的时刻)。
  void _persistPlayback({bool force = false}) {
    final dir = _info?.dataDir;
    if (dir == null || dir.isEmpty || _restoredFromDisk) return;
    final songs = _queue.items;
    if (songs.isEmpty) return;
    final now = DateTime.now();
    final last = _lastStateSave;
    if (!force &&
        last != null &&
        now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastStateSave = now;
    unawaited(
      PlaybackStateStore(dir).save(
        SavedPlayback(
          songs: songs,
          index: _queue.index < 0 ? 0 : _queue.index,
          positionMs: _player?.positionMs.toInt() ?? 0,
          mode: _queue.mode,
          libraryTitle: _libraryTitle,
        ),
      ),
    );
  }

  void _onAudioSettingsChanged() {
    final settings = AppSettings.instance;
    // 响度均衡的开关/目标电平变化 ⇒ 已算好的每曲增益全部作废, 当前曲目重算
    final loudnessChanged =
        settings.loudnessNormalize != _lastLoudnessNormalize ||
        settings.loudnessTargetLufs != _lastLoudnessTarget;
    _lastLoudnessNormalize = settings.loudnessNormalize;
    _lastLoudnessTarget = settings.loudnessTargetLufs;
    if (loudnessChanged) {
      forgetLoudnessGain();
      final id = _player?.trackId?.toInt();
      if (id != null) {
        _loudnessAppliedTrackId = id;
        unawaited(applyLoudnessForTrack(id));
      }
      return;
    }
    final request = AudioTuningRequest.fromSettings(settings);
    if (request != _lastTuning) {
      _lastTuning = request;
      unawaited(applyAudioTuning());
    }
    if (settings.cacheLimitMb != _lastCacheLimitMb) {
      _lastCacheLimitMb = settings.cacheLimitMb;
      unawaited(enforceCacheLimit(keepTrackId: _player?.trackId?.toInt()));
    }
  }

  Future<void> _pollPlayer() async {
    PlayerView state;
    try {
      state = await _playback.state();
    } catch (_) {
      return; // 播放后端未就绪(MediaController 连接中)时忽略
    }
    if (!mounted) return;
    // 恢复出来的"未加载现场": 播放器实际是空的, 别用它覆盖恢复出来的播放条
    if (_restoredFromDisk && state.trackId == null) return;
    final wasPlaying = _player?.playing ?? false;
    // 值没变就不 setState: 暂停时每 500ms 一次无意义的整页重建,
    // 除了费电还会让 uiautomator 之类"等空闲"的工具永远等不到稳定帧。
    final prev = _player;
    if (prev == null ||
        prev.trackId != state.trackId ||
        prev.playing != state.playing ||
        prev.positionMs != state.positionMs ||
        prev.durationMs != state.durationMs ||
        prev.volume != state.volume) {
      setState(() => _player = state);
    }
    // R2b: 曲目一换就按新曲目的响度给一次增益(未测则后台补测, 先按 0 dB 播)
    final playingId = state.trackId?.toInt();
    if (playingId != _loudnessAppliedTrackId) {
      _loudnessAppliedTrackId = playingId;
      // 歌词页背景跟随封面主色(node-vibrant 思路, 纯 Dart; 同 URL 有 LRU 缓存)
      unawaited(_syncCoverPalette());
      // 通知栏红心按钮跟当前曲目走
      unawaited(_syncActionState());
      if (playingId != null) {
        unawaited(
          applyLoudnessForTrack(
            playingId,
            streamUrl: _streamUrlByTrack[playingId],
          ),
        );
        unawaited(enforceCacheLimit(keepTrackId: playingId));
      }
    }
    // Android: 边听边存要整首存完才有"完整缓存 span", 所以播放中每 20s 补测一次
    if (playingId != null &&
        AppSettings.instance.loudnessNormalize &&
        !hasLoudnessGain(playingId)) {
      final now = DateTime.now();
      final last = _lastLoudnessRetry;
      if (last == null || now.difference(last) > const Duration(seconds: 20)) {
        _lastLoudnessRetry = now;
        unawaited(
          applyLoudnessForTrack(
            playingId,
            streamUrl: _streamUrlByTrack[playingId],
          ),
        );
      }
    }
    if (state.positionMs != BigInt.from(_wordPositionMs.value)) {
      _wordPositionMs.value = state.positionMs.toInt();
    }
    if (_playing.value != state.playing) _playing.value = state.playing;
    _syncLyricIndex(state);
    // 状态记忆: 播放中每 5s 落一次盘(暂停/换曲时会另有 force 落盘)
    if (state.playing) _persistPlayback();
    if (_looksEnded(wasPlaying, state)) {
      await _onTrackEnded();
    }
  }

  /// 播完判定: 从播放态落到非播放态, 且位置已在末尾附近.
  /// Media3/rodio 都不保证把 "ENDED" 送到 UI 层, 所以用轮询兜底.
  bool _looksEnded(bool wasPlaying, PlayerView s) {
    if (_userStopped ||
        _advancing ||
        _dragMs != null ||
        !wasPlaying ||
        s.playing) {
      return false;
    }
    if (s.durationMs == BigInt.zero) return false;
    return s.positionMs + BigInt.from(800) >= s.durationMs;
  }

  /// 原生 STATE_ENDED → 队列续播(与轮询兜底共用 [_onTrackEnded] 的临界区)
  void _onNativeTrackEnded() {
    if (_advancing) return;
    unawaited(_onTrackEnded());
  }

  Future<void> _onTrackEnded() async {
    if (_advancing) return;
    _advancing = true;
    try {
      final next = _queue.onEnded();
      if (next == null) {
        setState(() {}); // 顺序播放到队尾: 停在最后一首
        return;
      }
      await _playSong(next);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) return;
    final token = ++_searchToken;
    _suggestDebounce?.cancel();
    _searchFocus.unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _suggestions = const [];
      _exact = null;
      _keywordSuggestions = const [];
      // 搜索即离开歌单浏览态, 结果列表要保持"这一屏是什么"的唯一来源
      _library = const [];
      _libraryTitle = null;
      _libraryPlaylistId = null;
    });
    try {
      final result = await retryNetwork(
        () => rust.searchAll(keywords: keyword, limit: 20),
      );
      if (!mounted || token != _searchToken) return;
      setState(() => _bundle = result);
      // 搜索历史是本地记录, 失败不影响搜索结果
      try {
        final history = await rust.recordSearch(keyword: keyword);
        if (mounted) setState(() => _searchHistory = history);
      } catch (_) {}
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _error = friendlyError(e);
        _retryLast = _search;
      });
    } finally {
      if (mounted && token == _searchToken) setState(() => _busy = false);
    }
  }

  /// 显式取消: 清掉输入、上一轮结果、联想和错误, 回到搜索落地页
  void _clearSearch() {
    _searchToken += 1;
    _suggestDebounce?.cancel();
    _controller.clear();
    _searchFocus.unfocus();
    setState(() {
      _bundle = null;
      _suggestions = const [];
      _exact = null;
      _keywordSuggestions = const [];
      _error = null;
      _retryLast = null;
      _busy = false;
      _library = const [];
      _libraryTitle = null;
      _libraryPlaylistId = null;
    });
  }

  // ---------------- 搜索建议 / 历史 ----------------

  void _onSearchFocusChanged() {
    if (!mounted) return;
    if (!_searchFocus.hasFocus) {
      setState(() {
        _suggestions = const [];
        _exact = null;
        _keywordSuggestions = const [];
      });
    } else {
      // 重新获得焦点: 刷新历史(别处可能新增过)
      _loadSearchHistory();
      setState(() {});
    }
  }

  Future<void> _loadSearchHistory() async {
    try {
      final list = await rust.searchHistory();
      if (!mounted) return;
      setState(() => _searchHistory = list);
    } catch (_) {
      // 历史读不出来不影响主流程
    }
  }

  /// 搜索落地页的热词榜 + 默认/推荐搜索词. 两块互相独立, 失败不影响搜索.
  Future<void> _loadSearchLanding() async {
    if (mounted) setState(() => _hotLoading = true);
    try {
      // 热搜用 hotsearchlist(带服务端榜位/热度, 固定 20 条); 失败再退回老的热词接口
      List<rust.HotSearchTerm> hot;
      try {
        final detail = await retryNetwork(rust.hotSearchDetail);
        hot = [
          for (final it in detail)
            rust.HotSearchTerm(rank: it.rank, keyword: it.keyword),
        ];
        if (hot.isEmpty) hot = await retryNetwork(rust.hotSearch);
      } catch (_) {
        hot = await retryNetwork(rust.hotSearch);
      }
      if (!mounted) return;
      setState(() {
        _hotTerms = hot;
        _hotError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _hotError = friendlyError(e));
    } finally {
      if (mounted) setState(() => _hotLoading = false);
    }
    try {
      final recommended = await rust.defaultSearch();
      if (!mounted) return;
      setState(() {
        _recommendedKeyword = recommended?.keyword;
        _recommendedReason = recommended?.showText;
      });
    } catch (_) {
      // 推荐词是锦上添花, 失败静默
    }
  }

  void _onQueryChanged(String value) {
    _suggestDebounce?.cancel();
    // 让"清空/取消"按钮随输入内容即时出现
    if (mounted) setState(() {});
    final q = value.trim();
    if (q.isEmpty) {
      setState(() {
        _suggestions = const [];
        _exact = null;
        _keywordSuggestions = const [];
      });
      return;
    }
    _suggestDebounce = Timer(const Duration(milliseconds: 300), () async {
      // 三个来源并行: 联想卡片(web) / 精确实体(multimatch) / 纯关键词(mobile)
      final exactFuture = _loadExact(q);
      final keywordsFuture = _loadSuggestKeywords(q);
      try {
        final items = await rust.searchSuggest(keywords: q);
        if (!mounted || _controller.text.trim() != q) return;
        setState(() => _suggestions = items);
      } catch (_) {
        // 建议是锦上添花, 失败静默
      }
      final exact = await exactFuture;
      final keywords = await keywordsFuture;
      if (!mounted || _controller.text.trim() != q) return;
      setState(() {
        _exact = exact;
        _keywordSuggestions = keywords;
      });
    });
  }

  Future<rust.SearchExact?> _loadExact(String q) async {
    try {
      final exact = await rust.searchExact(keywords: q);
      // orders 为空就是空命中伪装成 200, 当作没有
      return exact.orders.isEmpty ? null : exact;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _loadSuggestKeywords(String q) async {
    try {
      return await rust.searchSuggestKeywords(keywords: q);
    } catch (_) {
      return const [];
    }
  }

  /// DTO -> 精确实体条视图(空命中由 SearchExactBar 自己隐藏)
  SearchExactView _exactView(rust.SearchExact e) => SearchExactView(
    orders: e.orders,
    artists: [
      for (final a in e.artists)
        SearchExactArtist(
          id: a.id.toInt(),
          name: a.name,
          avatarUrl: a.avatarUrl,
        ),
    ],
    playlists: [
      for (final p in e.playlists)
        SearchExactPlaylist(
          id: p.id.toInt(),
          name: p.name,
          coverUrl: p.coverUrl,
          trackCount: p.trackCount.toInt(),
        ),
    ],
    podcasts: [
      for (final r in e.podcasts)
        SearchExactRadio(
          id: r.id.toInt(),
          name: r.name,
          coverUrl: r.coverUrl,
          djName: r.djName,
          programCount: r.programCount.toInt(),
        ),
    ],
  );

  Future<void> _openExactArtist(int id) async {
    for (final a in _exact?.artists ?? const <rust.Artist>[]) {
      if (a.id.toInt() != id) continue;
      await showArtistDetail(
        context,
        artistId: a.id,
        name: a.name,
        onPlaySongs: (songs, i) => _playSongsList(songs, i),
        onOpenAlbum: (albumId, name, cover) => showAlbumPreview(
          context,
          albumId: albumId,
          albumName: name,
          coverUrl: cover,
          onPlay: (songs, i) => _playSongsList(songs, i),
        ),
      );
      return;
    }
  }

  Future<void> _openExactPlaylist(int id) async {
    for (final p in _exact?.playlists ?? const <rust.Playlist>[]) {
      if (p.id.toInt() == id) {
        await _openPlaylist(p);
        return;
      }
    }
  }

  void _openExactRadio(int id) {
    for (final r in _exact?.podcasts ?? const <rust.PodcastRadio>[]) {
      if (r.id.toInt() == id) {
        _openPodcastRadio(r);
        return;
      }
    }
  }

  Future<void> _searchKeyword(String keyword) async {
    _controller.text = keyword;
    _controller.selection = TextSelection.collapsed(offset: keyword.length);
    setState(() {
      _suggestions = const [];
      _exact = null;
      _keywordSuggestions = const [];
    });
    await _search();
  }

  Future<void> _clearSearchHistory() async {
    try {
      await rust.clearSearchHistory();
      if (mounted) setState(() => _searchHistory = const []);
    } catch (_) {}
  }

  /// 用一批曲目重置队列并从 index 开始播放(专辑/播客/每日推荐/最近听过共用).
  /// playlistId: 来源歌单(歌单详情页"定位正在播放"用), 不传即非歌单队列。
  Future<void> _playSongsList(
    List<rust.SongDto> songs,
    int index, {
    BigInt? playlistId,
    SongActionSource source = SongActionSource.other,
  }) async {
    if (songs.isEmpty) return;
    final start = index.clamp(0, songs.length - 1);
    _queue.setAll(songs, startAt: start);
    _playSource = source;
    _userStopped = false;
    setState(() {
      _library = songs;
      _libraryTitle = '正在播放';
      _libraryPlaylistId = null;
      _queuePlaylistId = playlistId;
    });
    await _playSong(songs[start], explicit: true);
  }

  // ---------------- 心动模式 / 每日推荐 / 播客 / 最近听过 / 封面预览 ----------------

  /// 心动模式: 以当前曲目为种子, 在当前歌单(0=不限定)里续播一队推荐.
  /// 网易云这个接口需要登录, 未登录会返回 [auth] 错误.
  Future<void> _heartMode({rust.SongDto? seed}) async {
    final current = seed ?? _current;
    final id = current?.id;
    if (id == null) {
      _toast('先播一首歌, 再开启心动模式');
      return;
    }
    setState(() => _busy = true);
    try {
      final songs = await retryNetwork(
        () => rust.heartModeSongs(
          songId: id,
          playlistId: _libraryPlaylistId ?? BigInt.zero,
          count: 30,
        ),
      );
      if (!mounted) return;
      final seen = <BigInt>{id};
      final list = <rust.SongDto>[?current];
      for (final s in songs) {
        if (s.playable && seen.add(s.id)) list.add(s);
      }
      if (list.length <= 1) {
        _toast('心动模式暂时没有推荐(登录后推荐更准)');
        return;
      }
      _queue.setAll(list, startAt: 0);
      _playSource = SongActionSource.other;
      _userStopped = false;
      setState(() {
        _library = list;
        _libraryTitle = '心动模式';
        _queuePlaylistId = null;
      });
      unawaited(_syncActionState());
      final next = _queue.next();
      if (next != null) await _playSong(next);
    } catch (e) {
      if (!mounted) return;
      _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showToast(context, message);
  }

  /// 每日推荐歌单(带本地缓存): 同一天第二次进页面直接读缓存, 离线也能出内容。
  ///
  /// 缓存口径见 `daily_cache.dart` 与 设置 → 缓存(保留天数 / 立即清理)。
  /// 未初始化(dataDir 未知)或用户关掉缓存时原样透传, 行为与没有缓存一致。
  Future<List<rust.Playlist>> _dailyPlaylists() {
    final dir = _info?.dataDir;
    if (dir == null || dir.isEmpty) return rust.dailyRecommendPlaylists();
    return DailyPlaylistCache(dataDir: dir).load(
      fetch: rust.dailyRecommendPlaylists,
      keepDays: AppSettings.instance.dailyCacheDays,
    );
  }

  void _openDiscover() {
    showDiscoverPage(
      context,
      // 日推队列: 详情页"..."里要能继续"不感兴趣"
      onPlaySongs: (songs, index) =>
          _playSongsList(songs, index, source: SongActionSource.dailyRecommend),
      onOpenPlaylist: (pl) => _openPlaylist(pl),
      loadPlaylists: _dailyPlaylists,
    );
  }

  /// 直接打开某个播客的详情页(推荐/我的页面的卡片点进来)
  /// 记录"最近一次交互"(我的页收藏栏按它排序, 见 recent_order.dart)。
  /// 打开动作是唯一可靠的信号: 收藏列表本身没有"最近使用"字段。
  void _touchInteraction(String kind, BigInt id) {
    if (id <= BigInt.zero) return;
    unawaited(AppSettings.instance.touchInteraction(kind, id));
  }

  void _openPodcastRadio(rust.PodcastRadio radio) {
    _touchInteraction('podcast', radio.id);
    showPodcastDetail(
      context,
      radio: radio,
      onPlaySongs: (songs, index) => _playSongsList(songs, index),
    );
  }

  void _openRecent() {
    showRecentPage(
      context,
      onPlay: (songs, index) => _playSongsList(songs, index),
      onOpenPlaylist: _openPlaylist,
      onOpenPodcast: _openPodcastRadio,
      onOpenAlbum: (album) => showAlbumPreview(
        context,
        albumId: album.id,
        albumName: album.name,
        coverUrl: album.coverUrl,
        onPlay: (songs, index) => _playSongsList(songs, index),
      ),
    );
  }

  /// 点列表: 用当前可见列表(搜索/歌单)重置队列, 从被点那首开始
  Future<void> _playFromList(rust.SongDto song) async {
    final songs = _visibleSongs;
    final start = songs.indexWhere((s) => s.id == song.id);
    _queue.setAll(songs, startAt: start < 0 ? 0 : start);
    _playSource = SongActionSource.other;
    _userStopped = false;
    _queuePlaylistId = null; // 搜索列表点播不算歌单队列
    await _playSong(song, explicit: true);
  }

  /// 搜索结果里点单曲: 用"可见单曲"重置队列(跳过无版权), 并定位到这首
  Future<void> _playFromSearch(rust.SongDto song) async {
    final songs = visibleSongs(
      _bundle?.songs ?? const <rust.SongDto>[],
      _liked,
    );
    final start = songs.indexWhere((s) => s.id == song.id);
    if (songs.isEmpty) return;
    _queue.setAll(songs, startAt: start < 0 ? 0 : start);
    _playSource = SongActionSource.other;
    _userStopped = false;
    _queuePlaylistId = null;
    await _playSong(song, explicit: true);
  }

  /// 搜索结果: 艺人卡片 → 艺人页
  Future<void> _openSearchArtist(rust.SearchArtist artist) async {
    await showArtistDetail(
      context,
      artistId: artist.id,
      name: artist.name,
      onPlaySongs: (songs, i) => _playSongsList(songs, i),
      onOpenAlbum: (id, name, cover) => showAlbumPreview(
        context,
        albumId: id,
        albumName: name,
        coverUrl: cover,
        onPlay: (songs, i) => _playSongsList(songs, i),
      ),
    );
  }

  void _openSearchAlbum(rust.SearchAlbum album) {
    showAlbumPreview(
      context,
      albumId: album.id,
      albumName: album.name,
      coverUrl: album.coverUrl,
      onPlay: (songs, i) => _playSongsList(songs, i),
    );
  }

  /// 搜索结果: 歌单卡片 → 歌单详情
  void _openSearchPlaylist(rust.SearchPlaylistItem item) {
    _openPlaylist(
      rust.Playlist(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        trackCount: item.trackCount,
        special: false,
        subscribed: false,
      ),
    );
  }

  /// 搜索结果: 播客卡片 → 播客详情
  void _openSearchPodcast(rust.SearchPodcast item) {
    _openPodcastRadio(
      rust.PodcastRadio(
        id: item.id,
        name: item.name,
        coverUrl: item.coverUrl,
        description: '',
        djName: item.djName,
        programCount: item.programCount,
        playCount: item.playCount,
      ),
    );
  }

  /// 当前设置下这首歌要不要跳过(口径见 playback_policy.dart, 已单测)。
  bool _skipVip(rust.SongDto song) => shouldSkipVipSong(
    song,
    skipVipEnabled: AppSettings.instance.skipVipSongs,
  );

  /// 跳过取不到直链的曲目(会员/版权限制)与设置里要求跳过的 VIP 曲目, 最多绕队列一圈。
  ///
  /// VIP 跳过是用户自己开的策略, 所以静默跳过、整轮结束才提示一次 —— 否则自动续播
  /// 会连环弹窗(与无版权曲目的处理口径一致)。
  ///
  /// [explicit] = 用户主动点选的这一首: 「自动跳过 VIP」只约束自动续播/切歌,
  /// 用户亲手点的歌必须播(官方也是这么做的 —— 会员曲目能试听前 30s),
  /// 只有取链真的拿不到直链时才继续往后跳。
  Future<void> _playSong(rust.SongDto song, {bool explicit = false}) async {
    _userStopped = false;
    _restoredFromDisk = false;
    _restoredResumeMs = 0;
    var allowVip = explicit;
    var attempts = 0;
    var skippedVip = 0;
    void reportSkipped() {
      if (skippedVip > 0 && mounted) {
        _toast('已跳过 $skippedVip 首 VIP 歌曲(可在设置里关闭)');
      }
    }

    var target = song;
    while (true) {
      if (!allowVip && _skipVip(target)) {
        skippedVip += 1;
      } else if (await _resolveAndPlay(target)) {
        reportSkipped();
        _persistPlayback(force: true);
        return;
      }
      // 跳过只发生在非主动点选的曲目上; 一旦绕到下一首就回到"自动续播"口径
      allowVip = false;
      attempts += 1;
      if (attempts >= _queue.items.length) {
        if (mounted) setState(() {});
        reportSkipped();
        return;
      }
      final next = _queue.next();
      if (next == null) return;
      target = next;
    }
  }

  /// 预取的下一首直链(曲目 id → 直链 + 档位 + 取得时间)。
  ///
  /// 为什么预取: 播完一首再去取链(数百毫秒)+ 让播放器重新 prepare, 表现为
  /// 连续播放每首之间都"卡一下"。提前把下一条直链拿到手, 换曲就只剩播放器
  /// 自己的缓冲。直链有时效(约几分钟到几十分钟), 所以带时间戳, 超过 4 分钟不用。
  final Map<int, ({String url, String level, DateTime at})> _prefetchedUrls =
      <int, ({String url, String level, DateTime at})>{};

  /// 取出可用的预取直链(一次性: 用过就删, 避免复用过期地址)
  String? _takePrefetchedUrl(int trackId, String level) {
    final hit = _prefetchedUrls.remove(trackId);
    if (hit == null) return null;
    if (hit.level != level) return null;
    if (DateTime.now().difference(hit.at) > const Duration(minutes: 4)) {
      return null;
    }
    return hit.url;
  }

  /// 后台预取"下一首"的直链(随机/单曲循环没有可预知的下一首, 直接跳过)。
  void _prefetchNextTrack() {
    final next = _queue.peekNext();
    if (next == null || !next.playable) return;
    final id = next.id.toInt();
    if (_prefetchedUrls.containsKey(id)) return;
    final level = AppSettings.instance.audioLevel;
    unawaited(() async {
      try {
        final stream = await rust.songUrl(trackId: next.id, level: level);
        final url = stream.url;
        if (url == null || url.isEmpty) return;
        _prefetchedUrls[id] = (url: url, level: level, at: DateTime.now());
        if (_prefetchedUrls.length > 8) {
          _prefetchedUrls.remove(_prefetchedUrls.keys.first);
        }
      } catch (_) {
        // 预取失败无所谓: 真正换曲时还会走一次正常取链
      }
    }());
  }

  /// 通知栏/锁屏封面缓存(按已经按档位裁好的 URL 存, 最多 8 张)。
  final Map<String, Uint8List> _notificationArtwork = <String, Uint8List>{};

  /// 取当前播放内容的封面字节给系统通知用(播客/歌曲/电台都走 coverUrl)。
  ///
  /// 超时 300ms 就放弃: 封面是锦上添花, 绝不能为了它把播放拖慢(用户要求
  /// "总是乐观播放已经得到的片段")。UI 上刚显示过的封面通常已在
  /// cover_art.dart 的字节 LRU 里, 这条 await 实际是微任务级别。
  Future<Uint8List?> _artworkFor(rust.SongDto song) async {
    final url = song.coverUrl;
    if (url == null || url.isEmpty) return null;
    final key = neteaseThumbUrl(httpsImageUrl(url), width: 512, height: 512);
    final cached = _notificationArtwork[key];
    if (cached != null) return cached;
    try {
      final bytes = await fetchImageBytes(key)
          .timeout(const Duration(milliseconds: 300));
      if (_notificationArtwork.length >= 8) {
        _notificationArtwork.remove(_notificationArtwork.keys.first);
      }
      _notificationArtwork[key] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _resolveAndPlay(rust.SongDto song) async {
    // 没版权的曲目连取链都不用试; 自动续播时静默跳过(点列表才提示, 否则一路弹窗)
    if (!song.playable) return false;
    try {
      // 先用预取的直链(有就用, 省掉几百毫秒); 没有才真的去取。
      final level = AppSettings.instance.audioLevel;
      var url = _takePrefetchedUrl(song.id.toInt(), level);
      if (url == null) {
        // 移动网络切网时会偶发 connection reset, 取链是幂等的, 值得重试
        final stream = await retryNetwork(
          () => rust.songUrl(trackId: song.id, level: level),
        );
        url = stream.url;
      }
      if (url == null) {
        if (mounted) {
          showToast(context, '《${song.name}》没有可用直链(会员曲目需先登录), 已跳过');
        }
        return false;
      }
      // Android 的响度均衡要靠这条直链去 Media3 的 SimpleCache 里找缓存文件;
      // 注意必须用**播放时实际用的**URL(playback.play 会把 http 升级成 https),
      // 否则 SimpleCache 的 key 对不上, 永远找不到缓存文件.
      final playingId = song.id.toInt();
      final cacheKeyUrl = preferHttpsStreamUrl(url);
      _streamUrlByTrack[playingId] = cacheKeyUrl;
      if (_streamUrlByTrack.length > 64) {
        _streamUrlByTrack.remove(_streamUrlByTrack.keys.first);
      }
      final state = await _playback.play(
        trackId: song.id,
        url: url,
        title: song.name,
        artist: song.artist,
        // 边下边播(桌面)时解码器拿不到总时长, 进度条用接口时长兜底
        durationMs: song.durationMs,
        // 通知栏图标 = 当前播放内容的封面(歌曲/播客统一走 coverUrl)
        artwork: await _artworkFor(song),
      );
      if (!mounted) return true;
      setState(() => _player = state);
      // 立刻按这首的响度给一次增益(未测到就先 0 dB, 轮询里会再补一次)
      _loudnessAppliedTrackId = playingId;
      unawaited(applyLoudnessForTrack(playingId, streamUrl: cacheKeyUrl));
      // 本地播放历史(未登录/离线时"最近听过"的来源); 失败不影响播放
      unawaited(rust.rememberPlay(song: song).catchError((_) => false));
      unawaited(_loadLyric(song.id));
      // 播放已经起来了, 顺手把下一首的直链拿到手(让连续播放不再每首卡一下)
      _prefetchNextTrack();
      return true;
    } catch (e) {
      if (!mounted) return false;
      showToast(context, friendlyError(e), isError: true);
      return false;
    }
  }

  // ---------------- 歌词 ----------------

  Future<void> _loadLyric(BigInt trackId) async {
    if (_lyricTrackId == trackId) return;
    _lyricTrackId = trackId;
    if (mounted) {
      setState(() {
        _lyricLines = const [];
        _lyricTimes = const [];
        _lyricPlain = null;
        _lyricIndex = -1;
        _lyricError = null;
        _wordLines = const [];
      });
      _wordPositionMs.value = 0;
    }
    // B13/C2: 逐字歌词来源决策(按用户偏好, auto 打分择优), loader 可注入(单测不联网)。
    final resolved = await resolveLyricSource(
      trackId,
      LyricSourceLoaders(
        yrc: (id) async => rust.wordLyricLines(trackId: id),
        ttml: (id) async => rust.ttmlLyricLines(trackId: id),
        lineLevel: (id) async => rust.lyricLinesI18N(trackId: id),
      ),
      preference: AppSettings.instance.lyricSourcePreference,
    );
    if (resolved != null && mounted && _lyricTrackId == trackId) {
      final word = resolved.word;
      if (word != null) {
        setState(() {
          _lyricError = null;
          _lyricPlain = null;
          _wordLines = [
            for (var i = 0; i < word.lines.length; i++)
              WordLyricLineData(
                startMs: word.lines[i].startMs,
                endMs: word.lines[i].endMs,
                words: [
                  for (final w in word.lines[i].words)
                    WordLyricWord(
                      startMs: w.startMs,
                      endMs: w.endMs,
                      text: w.text,
                    ),
                ],
                sub: i < word.translationLines.length
                    ? word.translationLines[i]
                    : null,
              ),
          ];
        });
        _wordPositionMs.value = _player?.positionMs.toInt() ?? 0;
        _playing.value = _player?.playing ?? false;
        return;
      }
      final lines = resolved.line;
      if (lines != null && lines.isNotEmpty) {
        setState(() {
          _lyricError = null;
          _lyricLines = [
            for (final l in lines)
              ParsedLyricLine(timeMs: l.timeMs, text: l.text, sub: l.sub),
          ];
          _lyricTimes = [for (final l in lines) l.timeMs];
        });
        _syncLyricIndex(_player ?? PlayerView.empty);
        return;
      }
    }
    try {
      final lines = await rust.lyricLinesI18N(trackId: trackId);
      if (!mounted || _lyricTrackId != trackId) return;
      if (lines.isNotEmpty) {
        setState(() {
          _lyricLines = [
            for (final l in lines)
              ParsedLyricLine(timeMs: l.timeMs, text: l.text, sub: l.sub),
          ];
          _lyricTimes = [for (final l in lines) l.timeMs];
        });
        _syncLyricIndex(_player ?? PlayerView.empty);
        return;
      }
      // 逐行接口没有内容(纯文本/老格式歌词) → 退回原始 LRC
      await _loadRawLyric(trackId);
    } catch (e) {
      if (!mounted || _lyricTrackId != trackId) return;
      // 兜底: 原始 LRC 里往往还有纯文本可显示; 都没有才报错
      final ok = await _loadRawLyric(trackId);
      if (!ok && mounted && _lyricTrackId == trackId) {
        setState(() => _lyricError = friendlyError(e));
      }
    }
  }

  /// 原始 LRC 兜底(逐行接口失败/为空时): 有时间轴就等价于逐行高亮,
  /// 只有纯文本就走 [PlainLyricView]。返回是否有内容可用。
  Future<bool> _loadRawLyric(BigInt trackId) async {
    try {
      final raw = await rust.lyric(trackId: trackId);
      if (!mounted || _lyricTrackId != trackId) return false;
      final doc = parseLrc(raw);
      if (doc.isEmpty) return false;
      setState(() {
        _lyricError = null;
        if (doc.hasTimeline) {
          _lyricPlain = null;
          _lyricLines = doc.timed;
          _lyricTimes = [for (final l in doc.timed) l.timeMs];
        } else {
          _lyricLines = const [];
          _lyricTimes = const [];
          _lyricPlain = doc.plain;
        }
      });
      if (doc.hasTimeline) _syncLyricIndex(_player ?? PlayerView.empty);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _syncLyricIndex(PlayerView state, {bool force = false}) {
    if (!_showLyrics || _lyricTimes.isEmpty) return;
    final idx = lyricIndexAt(_lyricTimes, state.positionMs);
    // force=true: seek(拖/点进度条、切歌)后即使落在同一句也要把列表滚回当前句
    if (idx == _lyricIndex && !force) return;
    setState(() => _lyricIndex = idx);
    _scrollLyricTo(idx);
  }

  void _scrollLyricTo(int idx) {
    if (!_autoFollowLyric) return;
    if (!_lyricScroll.hasClients || idx < 0) return;
    final position = _lyricScroll.position;
    final target =
        idx * _lyricItemExtent -
        (position.viewportDimension - _lyricItemExtent) / 2;
    final clamped = target.clamp(0.0, position.maxScrollExtent);
    _lyricScroll.animateTo(
      clamped,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOut,
    );
  }

  void _toggleLyrics() {
    setState(() {
      _showLyrics = !_showLyrics;
      // 每次进入详情页都恢复"跟随 + 无选中", 避免上次留下的状态让人困惑
      _autoFollowLyric = true;
      _selectedLyricLines.clear();
    });
    if (_showLyrics) {
      // 仅展开期间提高刷新频率; 收起/切 tab 时必须停掉。
      _lyricTicker?.cancel();
      _lyricTicker = Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => _pollPlayer(),
      );
      if (_player != null) {
        _syncLyricIndex(_player!);
        _wordPositionMs.value = _player!.positionMs.toInt();
        _playing.value = _player!.playing;
      }
    } else {
      _lyricTicker?.cancel();
      _lyricTicker = null;
    }
  }

  // ---------------- 详情页: 翻译 / 多选 / 分享 / 定位 ----------------

  /// 歌曲详情页(歌词页)是否可用: 就是歌词叠层本身, 从播放条点进来
  bool get _lyricSelecting => _selectedLyricLines.isNotEmpty;

  /// 歌词里有没有翻译(tlyric). 没有时整页不出现翻译开关, 免得点出个空开关
  bool get _hasLyricTranslation =>
      _wordLines.any((l) => (l.sub ?? '').trim().isNotEmpty) ||
      _lyricLines.any((l) => (l.sub ?? '').trim().isNotEmpty);

  /// 当前播放位置对应的歌词行(-1 = 还没唱到第一句)
  int get _currentLyricIndex {
    final pos = _player?.positionMs ?? BigInt.zero;
    if (_wordLines.isNotEmpty) return wordLineIndexAt(_wordLines, pos.toInt());
    if (_lyricTimes.isNotEmpty) return lyricIndexAt(_lyricTimes, pos);
    return -1;
  }

  /// 取第 [i] 行歌词的纯文本(逐字歌词把词拼回整行)
  String _lyricTextAt(int i) {
    if (_wordLines.isNotEmpty) {
      if (i < 0 || i >= _wordLines.length) return '';
      return [for (final w in _wordLines[i].words) w.text].join();
    }
    if (_lyricLines.isNotEmpty) {
      if (i < 0 || i >= _lyricLines.length) return '';
      return _lyricLines[i].text;
    }
    final plain = _lyricPlain;
    if (plain == null || i < 0 || i >= plain.length) return '';
    return plain[i];
  }

  /// 一键回到当前唱到的那句(并恢复跟随)
  void _locateCurrentLyric() {
    final idx = _currentLyricIndex;
    setState(() => _autoFollowLyric = true);
    if (idx < 0) {
      _toast('还没唱到第一句');
      return;
    }
    _scrollLyricTo(idx);
  }

  /// 用户手动滑歌词: 停止自动跟随(否则下一句会把列表拽回去, 根本看不远)
  void _pauseLyricFollow() {
    if (!_autoFollowLyric) return;
    setState(() => _autoFollowLyric = false);
  }

  /// 长按歌词行: 进入多选并选中该行; 之后点击任意行加/减选
  void _selectLyricLine(int index, {bool longPress = false}) {
    setState(() {
      if (longPress) {
        _selectedLyricLines.add(index);
      } else if (!_selectedLyricLines.remove(index)) {
        _selectedLyricLines.add(index);
      }
    });
    if (longPress && _selectedLyricLines.length == 1) {
      _toast('已选中 1 句歌词, 继续点击可多选');
    }
  }

  void _clearLyricSelection() {
    if (_selectedLyricLines.isEmpty) return;
    setState(() => _selectedLyricLines.clear());
  }

  /// 选中行的文本(按行号排序, 最多 8 行 —— 分享卡片放不下更多)
  List<String> _selectedLyricTexts() {
    final indexes = _selectedLyricLines.toList()..sort();
    return shareableLyricLines([
      for (final i in indexes) _lyricTextAt(i),
    ], max: 8);
  }

  void _toggleLyricTranslation() {
    final next = !AppSettings.instance.lyricTranslation;
    setState(() {});
    unawaited(AppSettings.instance.update(lyricTranslation: next));
  }

  /// 分享(详情页右上角 / 选中歌词后的分享): 卡片带封面 + 歌词 + 二维码
  Future<void> _shareSong({List<String>? lyrics}) async {
    final song = _current;
    if (song == null) {
      _toast('当前没有正在播放的歌曲');
      return;
    }
    await showSongShareSheet(
      context,
      song: song,
      lyricLines: lyrics ?? const <String>[],
    );
  }

  Future<void> _shareSelectedLyrics() async {
    final lines = _selectedLyricTexts();
    if (lines.isEmpty) {
      _toast('没有可分享的歌词');
      return;
    }
    await _shareSong(lyrics: lines);
  }

  // ---------------- 登录 ----------------

  /// 黑胶会员(只读)页面; 未登录时页面内给「登录」入口。
  /// 入口:「我的」页的「黑胶会员」行 / 账号与会员页的「会员」分组(审查 P1-7.9)。
  Future<void> _openVip() => showVipPage(context, onLogin: _login);

  Future<void> _login() async {
    // 桌面端: 官方网页登录的**扫码通道**(纯 Rust, 不依赖 WebView/系统 cookie).
    // 之前桌面端只能 ncm login-cookie, 等于把登录这一步踢给命令行, 体验断档.
    if (!_auth.isAndroid) {
      await showLoginSheet(
        context,
        onLoggedIn: () async {
          await _syncAccount();
          await _refreshInfo();
        },
        openWebLogin: () =>
            PlatformBridge.openUrl('https://music.163.com/#/login'),
      );
      return;
    }
    try {
      final cookie = await _auth.loginWeb();
      if (cookie == null) {
        if (!mounted) return;
        showToast(context, '未获取到登录态', isError: true);
        return;
      }
      final ok = await _auth.commitCookie(cookie);
      if (ok) {
        // 记住这个账号(昵称/uid) 并设为当前账号, 下次可直接切换
        await _syncAccount();
      }
      await _refreshInfo();
      if (!mounted) return;
      showToast(context, ok ? '登录成功, 账号已记住' : 'cookie 里没有 MUSIC_U, 登录未生效');
    } catch (e) {
      if (!mounted) return;
      showToast(context, '登录失败: ${friendlyError(e)}', isError: true);
    }
  }

  /// 账号管理页 —— 全 App 唯一账号面(账号簿/切换/添加/退出登录/清除凭据).
  /// 入口: 设置 → 账号管理 + 「我的」页资料头(资料本身可点进账号页)。
  Future<void> _openAccountPage() {
    return showAccountPage(
      context,
      info: _info,
      isAndroid: _auth.isAndroid,
      onLogin: _login,
      onLogout: () => _logout(),
      onSwitchAccount: _switchAccount,
      onRemoveAccount: (account) async {
        await rust.accountRemove(userId: account.userId);
        await _refreshInfo();
        if (!mounted) return;
        showToast(context, '已从账号簿移除');
      },
      // 隐私: 退出登录 + 删掉本机所有账号凭据(设备指纹保留).
      onPurgeLocal: () async {
        await _auth.logout();
        for (final account in await rust.accounts()) {
          await rust.accountRemove(userId: account.userId);
        }
        await _refreshInfo();
        if (!mounted) return;
        showToast(context, '已清除本机登录凭据');
      },
    );
  }

  /// 切换/重新登录账号(未登录时点账号簿里的一行也走这里).
  /// 返回是否真的切成功, 账号页据此把登录态翻成"已登录"。
  Future<bool> _switchAccount(rust.AccountDto account) async {
    final name = account.nickname.isEmpty
        ? account.userId.toString()
        : account.nickname;
    try {
      final ok = await rust.accountSwitch(userId: account.userId);
      await _refreshInfo();
      if (!mounted) return ok;
      showToast(context, ok ? '已切换到 $name' : '这个账号没存过凭据, 请重新登录');
      return ok;
    } catch (e) {
      if (!mounted) return false;
      showToast(context, '切换账号失败: ${friendlyError(e)}', isError: true);
      return false;
    }
  }

  /// refresh init 信息(登录态/设备 id/会员状态)
  Future<void> _refreshInfo() async {
    try {
      final dir = await _playback.dataDir();
      final info = await rust.init(dataDir: dir);
      if (mounted) setState(() => _info = info);
      // 登录/登出/切号都汇到 _refreshInfo, 在这里统一 drain Keystore 桥的 pending
      unawaited(credentialSync.drainPending());
      _actionsHost.value = _buildActionsHost();
      if (info.loggedIn) {
        await _loadLiked();
      } else {
        _liked = <BigInt>{};
      }
    } catch (_) {
      // init 失败保持旧状态
    }
  }

  /// 记账号资料(昵称/uid/会员)进账号簿; 离线拉不到只是没名字, 不影响登录态.
  ///
  /// 同时兼作**登录态校验**: 本地有 MUSIC_U 字符串不代表凭据还有效(过期/被踢/从别处
  /// 拷了数据目录). 只有服务端明确回 auth 错才清登录态 —— 网络/风控失败不动, 免得
  /// 一次网络抖动就把人踢下线.
  Future<void> _syncAccount() async {
    try {
      await rust.accountSyncActive();
    } catch (e) {
      if (!e.toString().contains('[auth]')) return;
      try {
        await rust.logout();
        await _refreshInfo();
        _toast('登录状态已失效, 请重新登录');
      } catch (_) {}
    }
  }

  /// 退出登录; thenLogin=true 表示切换账号(退出后立刻再开授权页)
  Future<void> _logout({bool thenLogin = false}) async {
    try {
      await _auth.logout();
      await _refreshInfo();
      if (!mounted) return;
      showToast(context, thenLogin ? '已退出, 请登录另一个账号' : '已退出登录(账号仍留在账号簿)');
      if (thenLogin) await _login();
    } catch (e) {
      if (!mounted) return;
      showToast(context, '退出登录失败: ${friendlyError(e)}', isError: true);
    }
  }

  // ---------------- 收藏(红心)与歌单 ----------------

  /// 拉一次"我喜欢的音乐"的 id 集合. 失败不影响播放, 只是红心状态未知。
  Future<void> _loadLiked() async {
    try {
      final ids = await retryNetwork(rust.likedIds);
      if (!mounted) return;
      setState(() => _liked = ids.toSet());
    } catch (_) {}
  }

  bool _isLiked(BigInt? trackId) => trackId != null && _liked.contains(trackId);

  /// "..." 菜单的回调宿主(登录态变化时重建)
  SongActionHost _buildActionsHost() => SongActionHost(
    loggedIn: _info?.loggedIn == true,
    isLiked: _isLiked,
    toggleLike: _toggleLikeFor,
    playNext: _playNextSong,
    addToPlaylist: _showAddToPlaylist,
    share: _showShareSong,
    comments: _showSongComments,
    openArtist: _openSongArtist,
    openAlbum: _openSongAlbum,
    download: _downloadSong,
    dislike: _dislikeSong,
    songWiki: (song) => showSongWiki(context, song: song),
    counts: _loadSongCounts,
    similarSongs: (song) => showSimilarSongs(
      context,
      song: song,
      onPlay: _playSongsList,
      onOpenPlaylist: _openPlaylist,
    ),
  );

  /// 歌曲菜单里的三项数量级: 喜欢人数 / 评论数 / 分享数(与原版对齐).
  ///
  /// 数据来源:
  /// - 评论数 + 分享数: 评论线程统计 `R_SO_4_<id>`(我们本来就有这接口);
  /// - 喜欢人数: 官方 App 的 `/api/song/like/get`(`likedCount`), api-enhanced
  ///   里没有这个模块, 从官方客户端抓到的路径, 已按 vendor 规则加到 vendor 侧。
  ///   该接口**需要登录**, 匿名返回 301 —— 未登录时不显示, 菜单其余项不受影响。
  ///
  /// 任何一项失败都只是"这一项不显示", 绝不让菜单报错。
  Future<SongActionCounts> _loadSongCounts(rust.SongDto song) async {
    final id = song.id;
    Future<String?> likedLabel() async {
      if (_info?.loggedIn != true) return null;
      try {
        final state = await rust.songLikeState(trackId: id);
        return formatCountMagnitude(state.likedCount.toInt());
      } catch (_) {
        return null;
      }
    }

    Future<rust.CommentStats?> stats() async {
      try {
        return await rust.commentStats(threadId: 'R_SO_4_$id');
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait<Object?>([likedLabel(), stats()]);
    final liked = results[0] as String?;
    final s = results[1] as rust.CommentStats?;
    String? comments;
    if (s != null) {
      // 上游自带官方文案("100w+"/"999+")优先, 没有才用我们的量级口径
      final desc = s.commentCountDesc.trim();
      comments = desc.isNotEmpty
          ? desc
          : formatCountMagnitude(s.commentCount.toInt());
    }
    final shares = s == null
        ? null
        : formatCountMagnitude(s.shareCount.toInt());
    return SongActionCounts(liked: liked, comments: comments, shares: shares);
  }

  /// 任意曲目的红心切换(列表/播放条共用; 先乐观更新, 失败回滚)
  Future<void> _toggleLikeFor(rust.SongDto song) async {
    if (_info?.loggedIn != true) {
      _toast('收藏需要先登录');
      return;
    }
    final id = song.id;
    final wasLiked = _liked.contains(id);
    setState(() {
      if (wasLiked) {
        _liked.remove(id);
      } else {
        _liked.add(id);
      }
    });
    try {
      await rust.setLiked(trackId: id, liked: !wasLiked);
      // 通知栏红心按钮同步(当前曲目才影响通知图标, _syncActionState 里已取 _current)
      if (id == _current?.id) unawaited(_syncActionState());
      // 取消喜欢只给一条 3 秒提示, 不给「撤销」按钮:
      // 红心本身一点就回来(再点一次), 而带 action 的撤销条会在底部常驻更久、
      // 压住播放条和内容(用户反馈"不会自动回落, 遮挡内容")。
      if (wasLiked && mounted) {
        showToast(context, '已取消喜欢《${song.name}》');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        if (wasLiked) {
          _liked.add(id);
        } else {
          _liked.remove(id);
        }
      });
      if (id == _current?.id) unawaited(_syncActionState());
      rethrow;
    }
  }

  /// 歌单内搜索后"只添加当前歌": 保留现有队列, 追加到队尾(已在队列则不重复)
  Future<void> _appendSongToQueue(rust.SongDto song) async {
    if (_queue.isEmpty) {
      await _playSongsList([song], 0);
      return;
    }
    final existed = _queue.items.any((s) => s.id == song.id);
    _queue.append(song);
    if (!mounted) return;
    setState(() {});
    _toast(existed ? '这首歌已在播放队列中' : '已添加到播放队列');
  }

  Future<void> _playNextSong(rust.SongDto song) async {
    _queue.insertNext(song);
    if (mounted) {
      setState(() {});
      _toast('已添加到下一首播放');
    }
  }

  /// 收藏到歌单: 先选歌单, 再调接口. "我喜欢的音乐"走红心接口.
  Future<void> _showAddToPlaylist(rust.SongDto song) async {
    if (_info?.loggedIn != true) {
      _toast('收藏到歌单需要先登录');
      return;
    }
    final lists = await retryNetwork(rust.myPlaylists);
    if (!mounted) return;
    // 返回 PlaylistDto(选已有歌单) 或 'create'(新建歌单)
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: Column(
            children: [
              SheetHeader(title: '收藏到歌单', subtitle: song.name),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  child: const Icon(Icons.add, size: 20),
                ),
                title: const Text('新建歌单'),
                subtitle: const Text('创建后把这首加进去'),
                onTap: () => Navigator.pop(sheetContext, 'create'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final pl = lists[i];
                    return ListTile(
                      dense: true,
                      leading: CoverArt(url: pl.coverUrl, size: 40, radius: 4),
                      title: Text(
                        pl.special ? '我喜欢的音乐' : pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${pl.trackCount} 首'),
                      onTap: () => Navigator.pop(sheetContext, pl),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    if (picked is String) {
      await _createPlaylistAndAdd(song);
      return;
    }
    final pl = picked as rust.Playlist;
    if (pl.special) {
      await rust.setLiked(trackId: song.id, liked: true);
      if (!mounted) return;
      setState(() => _liked.add(song.id));
      _toast('已加入我喜欢的音乐');
      return;
    }
    final ok = await rust.addToPlaylist(playlistId: pl.id, trackId: song.id);
    if (!mounted) return;
    _toast(ok ? '已收藏到《${pl.name}》' : '收藏未生效, 请稍后重试');
  }

  /// 新建歌单并把当前歌曲放进去
  Future<void> _createPlaylistAndAdd(rust.SongDto song) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await rust.createPlaylist(name: name, privacy: 0);
      final ok = await rust.addToPlaylist(playlistId: id, trackId: song.id);
      if (!mounted) return;
      _toast(ok ? '已新建《$name》并收藏' : '歌单已建, 收藏未生效');
    } catch (e) {
      if (!mounted) return;
      _toast('新建歌单失败: ${friendlyError(e)}');
    }
  }

  Future<void> _showShareSong(rust.SongDto song) async {
    final link = 'https://music.163.com/#/song?id=${song.id}';
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHeader(title: '分享'),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享到动态'),
              onTap: () async {
                Navigator.pop(sheetContext);
                try {
                  final ok = await rust.shareResource(
                    kind: 'song',
                    resourceId: song.id,
                    msg: song.name,
                  );
                  if (mounted) _toast(ok ? '已分享到动态' : '分享未生效');
                } catch (e) {
                  if (mounted) _toast(friendlyError(e));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制链接'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await Clipboard.setData(ClipboardData(text: link));
                if (mounted) _toast('链接已复制');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSongComments(rust.SongDto song) async {
    await showCommentsSheet(
      context,
      kind: 'song',
      resourceId: song.id,
      title: '《${song.name}》的评论',
    );
  }

  Future<void> _openSongArtist(rust.SongDto song) async {
    if (song.artistId == BigInt.zero) {
      _toast('这首歌没有关联艺人信息');
      return;
    }
    await showArtistDetail(
      context,
      artistId: song.artistId,
      name: song.artist,
      onPlaySongs: (songs, i) => _playSongsList(songs, i),
      onOpenAlbum: (id, name, cover) => showAlbumPreview(
        context,
        albumId: id,
        albumName: name,
        coverUrl: cover,
        onPlay: (songs, i) => _playSongsList(songs, i),
      ),
    );
  }

  Future<void> _openSongAlbum(rust.SongDto song) async {
    await showAlbumPreview(
      context,
      albumId: song.albumId,
      albumName: song.album,
      coverUrl: song.coverUrl,
      onPlay: (songs, i) => _playSongsList(songs, i),
    );
  }

  Future<void> _downloadSong(rust.SongDto song) async {
    _toast('正在获取下载地址…');
    try {
      final stream = await retryNetwork(
        () => rust.songUrl(
          trackId: song.id,
          level: AppSettings.instance.audioLevel,
        ),
      );
      final raw = stream.url;
      if (raw == null || raw.isEmpty) {
        _toast('这首歌暂时没有可用直链(会员/版权限制)');
        return;
      }
      final url = preferHttpsStreamUrl(raw);
      final ext = url.contains('.flac') ? 'flac' : 'mp3';
      final name = '${song.artist} - ${song.name}.$ext';
      final saved = await PlatformBridge.download(url: url, filename: name);
      if (!mounted) return;
      _toast(saved == null ? '下载失败' : '已开始下载(Android 在通知栏/Download 目录)');
    } catch (e) {
      if (!mounted) return;
      _toast('下载失败: ${friendlyError(e)}');
    }
  }

  /// 无版权提示(与官方一致的"点了才告诉你")
  void _notifyUnplayable(rust.SongDto song) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('《${song.name}》暂无版权, 无法播放'),
          duration: const Duration(milliseconds: 1800),
        ),
      );
  }

  /// 红心/取消红心(当前曲目). 先乐观更新, 失败回滚。
  Future<void> _toggleLike() async {
    final song = _current;
    if (song == null) return;
    try {
      await _toggleLikeFor(song);
    } catch (e) {
      if (mounted) _toast('收藏失败: ${friendlyError(e)}');
    }
  }

  /// 当前播放队列的来源(决定歌曲详情页"..."里能否出现"不感兴趣":
  /// 后端只接受每日推荐(dislike_recommend_song)与私人FM(fm_trash)这两个来源)。
  ///
  /// 之前这里是个粘性的 `_fmActive` 布尔: 播过一次 FM 就永远为 true, 之后从
  /// 每日推荐播的歌也走 fm_trash; 详情页的菜单来源又硬编码成 other,
  /// 所以日推歌曲在详情页里根本看不到"不感兴趣"(用户回归反馈)。
  /// 现在每次开始播放都显式记来源, 详情页菜单直接读这个字段。
  SongActionSource _playSource = SongActionSource.other;

  /// 不感兴趣: FM 队列里走"不再播放", 其它场景走"少推这类歌"
  Future<void> _dislikeSong(rust.SongDto song) async {
    if (_info?.loggedIn != true) {
      _toast('不感兴趣需要先登录');
      return;
    }
    try {
      if (_playSource == SongActionSource.personalFm) {
        await rust.trashFmSong(songId: song.id);
        if (!mounted) return;
        _toast('已从私人FM里去掉《${song.name}》');
      } else {
        await rust.dislikeRecommendSong(songId: song.id);
        if (!mounted) return;
        _toast('已减少《${song.name}》这类推荐');
      }
    } catch (e) {
      if (!mounted) return;
      _toast('操作失败: ${friendlyError(e)}');
    }
  }

  /// 打开"关注/粉丝"列表(当前账号)
  Future<void> _openUserList({required bool startOnFans}) async {
    if (_info?.loggedIn != true) {
      _toast('登录后才能查看关注与粉丝');
      return;
    }
    await showUserList(
      context,
      startOnFans: startOnFans,
      onPlaySongs: (songs, i) => _playSongsList(songs, i),
    );
  }

  /// 打开歌单详情页(全屏路由): 曲目/收藏/分享/评论都在详情页里,
  /// 不再把曲目塞进搜索页列表。
  Future<void> _openPlaylist(rust.Playlist pl) async {
    _touchInteraction('playlist', pl.id);
    await showPlaylistDetail(
      context,
      playlistId: pl.id,
      name: pl.name,
      coverUrl: pl.coverUrl,
      special: pl.special,
      loggedIn: _info?.loggedIn == true,
      likedIds: _liked,
      currentTrackId: _current?.id,
      currentPlaylistId: _queuePlaylistId,
      onPlaySongs: (songs, i) => _playSongsList(songs, i, playlistId: pl.id),
      onAppendSong: _appendSongToQueue,
      onLikeChanged: (id, liked) => setState(() {
        if (liked) {
          _liked.add(id);
        } else {
          _liked.remove(id);
        }
      }),
    );
  }

  /// 从"我的"页打开"我喜欢的音乐"详情(要用 myPlaylists 找到这个歌单的 id)
  /// 解析"我喜欢的音乐"歌单 id(缓存). 失败静默: 只是"定位正在播放"少一个依据.
  Future<void> _resolveLikedPlaylistId() async {
    if (_likedPlaylistId != null) return;
    try {
      final pls = await rust.myPlaylists();
      for (final p in pls) {
        if (p.special) {
          if (mounted) setState(() => _likedPlaylistId = p.id);
          return;
        }
      }
    } catch (_) {
      // 未登录/网络异常: 下次进"我喜欢的音乐"详情时再试
    }
  }

  Future<void> _openLikedDetail() async {
    if (_info?.loggedIn != true) {
      _toast('登录后才能查看我喜欢的音乐');
      return;
    }
    setState(() => _busy = true);
    try {
      final pls = await retryNetwork(rust.myPlaylists);
      if (!mounted) return;
      rust.Playlist? found;
      for (final p in pls) {
        if (p.special) {
          found = p;
          break;
        }
      }
      final sp = found;
      if (sp == null) {
        _toast('没有找到"我喜欢的音乐"歌单');
        return;
      }
      _likedPlaylistId = sp.id;
      await showPlaylistDetail(
        context,
        playlistId: sp.id,
        name: '我喜欢的音乐',
        coverUrl: sp.coverUrl,
        special: true,
        loggedIn: _info?.loggedIn == true,
        likedIds: _liked,
        currentTrackId: _current?.id,
        currentPlaylistId: _queuePlaylistId,
        onPlaySongs: (songs, i) => _playSongsList(songs, i, playlistId: sp.id),
        onAppendSong: _appendSongToQueue,
        onLikeChanged: (id, liked) => setState(() {
          if (liked) {
            _liked.add(id);
          } else {
            _liked.remove(id);
          }
        }),
      );
    } catch (e) {
      if (!mounted) return;
      _toast(friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 退出歌单浏览, 回到搜索
  void _closeLibrary() {
    setState(() {
      _library = const [];
      _libraryTitle = null;
      _libraryPlaylistId = null;
    });
  }

  // ---------------- 播放控制 ----------------

  Future<void> _toggle() async {
    // 还没真正加载(启动时恢复的现场 / 空播放器): 按播放 = 开始这一首
    if (_restoredFromDisk || _player?.trackId == null) {
      final song = _current;
      if (song != null) {
        final resume = _restoredResumeMs;
        _restoredFromDisk = false;
        _restoredResumeMs = 0;
        await _playSong(song, explicit: true);
        if (resume > 0 && mounted) await _seekTo(resume.toDouble());
        return;
      }
    }
    final playing = _player?.playing ?? false;
    final state = playing ? await _playback.pause() : await _playback.resume();
    if (!mounted) return;
    setState(() => _player = state);
    // 状态记忆: 暂停/继续都立刻记一次位置(退出时最多差 5s)
    _persistPlayback(force: true);
  }

  Future<void> _next() async {
    final next = _queue.next();
    if (next == null) return;
    _restoredFromDisk = false;
    await _playSong(next);
  }

  Future<void> _previous() async {
    final prev = _queue.previous();
    if (prev == null) return;
    _restoredFromDisk = false;
    await _playSong(prev);
  }

  /// 队列面板是否已展开.
  ///
  /// 播放条挂在根 Overlay(Navigator 之外), 队列面板打开后播放条仍然可点 ——
  /// 之前每点一次队列按钮就再压一层面板, 能无限叠加(用户反馈)。
  /// 现在已展开时再点 = 收起。
  bool _queueSheetOpen = false;

  /// 播放队列面板: 看队列 / 点项跳播 / 滑删或长按删(原来只有 "$inQueue/$total" 文本, 完全黑箱)
  Future<void> _openQueueSheet() async {
    if (_queueSheetOpen) {
      // 面板在栈顶; pop 掉它即"收起"
      Navigator.of(context).pop();
      return;
    }
    if (_queue.items.isEmpty) {
      _toast('播放队列是空的');
      return;
    }
    _queueSheetOpen = true;
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: PlayQueueSheet(
            items: _queue.items,
            index: _queue.index,
            onSelect: (song) {
              Navigator.of(sheetContext).pop();
              _jumpToQueueSong(song);
            },
            onRemove: _removeFromQueue,
            onMove: _moveInQueue,
            onClear: _clearQueue,
            onSaveAsPlaylist: _saveQueueAsPlaylist,
          ),
        ),
      );
    } finally {
      _queueSheetOpen = false;
    }
  }

  /// 队列面板拖拽排序: PlayQueue 自己修下标, 当前曲目不变 ⇒ 不需要重播/换歌
  void _moveInQueue(int from, int to) {
    if (!mounted) return;
    setState(() => _queue.moveTo(from, to));
  }

  /// 队列面板「清空」: 面板已经做过二次确认, 这里只负责清队列 + 停播
  Future<void> _clearQueue() async {
    if (!mounted) return;
    setState(() => _queue.clear());
    await _stopAfterQueueEmpty();
  }

  /// 队列面板「存为歌单」: 选已有歌单或新建, 把队列(面板已按 id 去重)整批加进去.
  /// 批量走 playlistTracksAdd(vendor /playlist/manipulate/tracks 原生支持多 id);
  /// 「我喜欢的音乐」(special)在官方网页端也走同一接口, 不再单独走红心.
  Future<void> _saveQueueAsPlaylist(List<rust.SongDto> songs) async {
    if (songs.isEmpty || !mounted) return;
    if (_info?.loggedIn != true) {
      _toast('存为歌单需要先登录');
      return;
    }
    List<rust.Playlist> lists;
    try {
      lists = await retryNetwork(rust.myPlaylists);
    } catch (e) {
      if (!mounted) return;
      _toast('存为歌单失败: ${friendlyError(e)}');
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(sheetContext).size.height * 0.6,
          child: Column(
            children: [
              SheetHeader(
                title: '存为歌单',
                subtitle: '把队列里的 ${songs.length} 首歌存进去',
              ),
              const Divider(height: 1),
              ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 20,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest,
                  child: const Icon(Icons.add, size: 20),
                ),
                title: const Text('新建歌单'),
                subtitle: const Text('创建后把队列加进去'),
                onTap: () => Navigator.pop(sheetContext, 'create'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: lists.length,
                  itemBuilder: (context, i) {
                    final pl = lists[i];
                    return ListTile(
                      dense: true,
                      leading: CoverArt(url: pl.coverUrl, size: 40, radius: 4),
                      title: Text(
                        pl.special ? '我喜欢的音乐' : pl.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${pl.trackCount} 首'),
                      onTap: () => Navigator.pop(sheetContext, pl),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked is String) {
      await _createPlaylistFromQueue(songs);
      return;
    }
    final pl = picked as rust.Playlist;
    await _addQueueToPlaylist(pl, songs);
  }

  /// 新建歌单并把整个队列存进去(默认名: 来自播放队列 M-D HH:mm)
  Future<void> _createPlaylistFromQueue(List<rust.SongDto> songs) async {
    final controller = TextEditingController(text: _queuePlaylistDefaultName());
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新建歌单'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: '歌单名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || !mounted) return;
    try {
      final id = await rust.createPlaylist(name: name, privacy: 0);
      final ok = await rust.playlistTracksAdd(
        playlistId: id,
        songIds: _queueSongIds(songs),
      );
      if (!mounted) return;
      _toast(ok ? '已存入《$name》, ${songs.length} 首' : '歌单已建, 加入未生效');
    } catch (e) {
      if (!mounted) return;
      _toast('存为歌单失败: ${friendlyError(e)}');
    }
  }

  /// 把队列存进已有歌单
  Future<void> _addQueueToPlaylist(
    rust.Playlist pl,
    List<rust.SongDto> songs,
  ) async {
    try {
      final ok = await rust.playlistTracksAdd(
        playlistId: pl.id,
        songIds: _queueSongIds(songs),
      );
      if (!mounted) return;
      final shown = pl.special ? '我喜欢的音乐' : pl.name;
      _toast(ok ? '已存入《$shown》, ${songs.length} 首' : '加入未生效, 请稍后重试');
    } catch (e) {
      if (!mounted) return;
      _toast('存为歌单失败: ${friendlyError(e)}');
    }
  }

  Uint64List _queueSongIds(List<rust.SongDto> songs) =>
      Uint64List.fromList([for (final s in songs) s.id.toInt()]);

  /// 「存为歌单」的默认歌单名
  String _queuePlaylistDefaultName() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '来自播放队列 ${now.month}-${now.day} ${two(now.hour)}:${two(now.minute)}';
  }

  /// 队列面板里点某一首: 定位到它再播(曲目可能已被别处挪过, 重新查下标)
  Future<void> _jumpToQueueSong(rust.SongDto song) async {
    final i = _queue.items.indexOf(song);
    if (i < 0) return;
    setState(() => _queue.jumpTo(i));
    await _playSong(song, explicit: true);
  }

  /// 队列面板删除: 删的不是当前项时只动列表; 删的是当前项时明确换到顶上来的下一首,
  /// 队列被删空则停播(否则播放器会继续放一首已经从队列里消失的歌)
  void _removeFromQueue(rust.SongDto song, bool wasCurrent) {
    final i = _queue.items.indexOf(song);
    if (i < 0) return;
    setState(() => _queue.removeAt(i));
    if (!wasCurrent) return;
    final next = _queue.current;
    if (next == null) {
      unawaited(_stopAfterQueueEmpty());
    } else {
      unawaited(_playSong(next));
    }
  }

  Future<void> _stopAfterQueueEmpty() async {
    _userStopped = true;
    // 队列没了就没有"现场"可恢复; 不清的话下次启动会恢复出一个空壳播放条
    final dir = _info?.dataDir;
    if (dir != null && dir.isNotEmpty) {
      unawaited(PlaybackStateStore(dir).clear());
    }
    _toast('播放队列已清空, 播放已停止');
    try {
      final state = await _playback.stop();
      if (mounted) setState(() => _player = state);
    } catch (_) {
      // 播放后端未就绪时忽略: 队列已经是空, UI 保持一致
    }
  }

  /// 播放顺序轮转: 列表循环 → 单曲 → 顺序 → 随机 → 心动 → 列表循环。
  ///
  /// 心动模式是否可用由 _heartMode 自己判断(未登录/无种子时会给提示并回落),
  /// 切换成功/失败的反馈用顶部浮层, 不挡播放条上那个按钮(用户反馈)。
  Future<void> _cycleMode() async {
    if (_heartActive) {
      setState(() => _queue.mode = PlayMode.repeatAll);
      _toastTop(playModeLabels[PlayMode.repeatAll]!);
      unawaited(_syncActionState());
      return;
    }
    final next = nextNotificationMode(_queue.mode);
    if (next == null) {
      await _heartMode();
      if (_heartActive) {
        _toastTop('心动模式');
      } else {
        setState(() => _queue.mode = PlayMode.repeatAll);
        _toastTop(playModeLabels[PlayMode.repeatAll]!);
      }
    } else {
      setState(() => _queue.mode = next);
      _toastTop(playModeLabels[next]!);
    }
    unawaited(_syncActionState());
  }

  /// 顶部短浮层: 只做"模式切换"这类即时反馈, 不拦截点击、不遮播放条按钮。
  void _toastTop(String message) {
    if (!mounted) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final scheme = Theme.of(context).colorScheme;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: MediaQuery.paddingOf(ctx).top + 12,
        left: 0,
        right: 0,
        child: IgnorePointer(
          child: Center(
            child: Material(
              color: scheme.inverseSurface,
              elevation: 4,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  message,
                  style: TextStyle(
                    color: scheme.onInverseSurface,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Timer(const Duration(milliseconds: 900), () {
      if (entry.mounted) entry.remove();
    });
  }

  /// 是否处于心动模式队列(心动不是 PlayMode, 用队列标题识别)
  bool get _heartActive => _libraryTitle == '心动模式';

  /// 当前曲目封面主色(歌词页背景用); null = 回退主题色
  CoverPalette? _coverPalette;

  /// 上一次取色对应的封面 URL, 避免同一封面重复触发
  String? _coverPaletteUrl;

  /// 曲目切换后重算封面主色. 同 URL 命中 cover_palette 的 LRU 缓存, 不会重复计算.
  Future<void> _syncCoverPalette() async {
    final url = _current?.coverUrl;
    if (url == _coverPaletteUrl) return;
    _coverPaletteUrl = url;
    if (url == null || url.isEmpty) {
      if (mounted && _coverPalette != null) {
        setState(() => _coverPalette = null);
      }
      return;
    }
    final palette = await paletteFromUrl(url);
    if (!mounted || _coverPaletteUrl != url) return; // 期间又换曲, 丢弃旧结果
    setState(() => _coverPalette = palette);
  }

  /// 把当前红心/模式状态回传给原生, 刷新通知自定义按钮图标
  Future<void> _syncActionState() async {
    await _playback.setActionState(
      liked: _isLiked(_current?.id),
      modeIcon: notificationModeIcon(_queue.mode, heartActive: _heartActive),
    );
  }

  /// 通知栏「播放顺序」按钮: 列表循环→单曲循环→顺序播放→随机播放→心动模式→(回到)列表循环.
  /// 心动模式那一步调 _heartMode(); 未登录/失败时 _heartMode 会自己 toast, 这里回退列表循环.
  Future<void> _cycleModeFromNotification() async {
    if (_heartActive) {
      setState(() => _queue.mode = PlayMode.repeatAll);
      _toast('列表循环');
    } else {
      final next = nextNotificationMode(_queue.mode);
      if (next == null) {
        await _heartMode();
        if (!mounted) return;
        if (!_heartActive) {
          setState(() => _queue.mode = PlayMode.repeatAll);
          _toast('列表循环');
        }
      } else {
        setState(() => _queue.mode = next);
        _toastTop(playModeLabels[next]!);
      }
    }
    await _syncActionState();
  }

  Future<void> _seekTo(double ms) async {
    final target = ms.round();
    // seek 是用户的明确意图: 无论之前是否拖过歌词, seek 后都恢复自动跟随,
    // 否则一次误触/拖动歌词后, 歌词从此不再跟着播放滚动(拖/点进度条都算 seek).
    setState(() {
      _dragMs = null;
      _dragMax = null;
      _autoFollowLyric = true;
    });
    final state = await _playback.seek(BigInt.from(target));
    if (!mounted) return;
    setState(() => _player = state);
    _syncLyricIndex(state, force: true);
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final backAction = resolveHomeBackAction(
      showLyrics: _showLyrics,
      tab: _tab,
      libraryOpen: _libraryTitle != null,
    );
    return HomeBackGuard(
      action: backAction,
      onBack: () => _handleBack(backAction),
      child: _buildPage(context),
    );
  }

  /// 返回键: 先退一级(歌词 → 非首 tab → 歌单浏览态), 栈底才交还系统退出
  void _handleBack(HomeBackAction action) {
    switch (action) {
      case HomeBackAction.collapseLyrics:
        // 详情页里正在多选歌词时, 返回键先退多选(与常见相册/文件选择一致)
        if (_lyricSelecting) {
          _clearLyricSelection();
        } else {
          _toggleLyrics();
        }
      case HomeBackAction.resetTab:
        _onTabSelected(0);
      case HomeBackAction.closeLibrary:
        _closeLibrary();
      case HomeBackAction.exitApp:
        // canPop=true 时由系统退出; 走到这里说明确实无可退层级, 兜底交还系统
        SystemNavigator.pop();
    }
  }

  Widget _buildPage(BuildContext context) {
    final player = _player;
    final current = _current;
    final topBar = _buildTopBar(context, current);
    // 播放条数据快照 + 底部导航由根布局渲染(MaterialApp.builder 的 PlayerBarHost):
    // 二级路由压上来时播放条仍然在场, 这里只负责把当前数据投递过去.
    _publishPlayerBar(player, current);
    _publishBottomBar(_buildBottomBar());
    return Scaffold(
      appBar: topBar,
      // 没有 AppBar 时自己吃掉状态栏安全区(放在最外层, 搜索框/内容都不会顶到状态栏下)
      body: Padding(
        padding: EdgeInsets.only(
          top: topBar == null ? MediaQuery.paddingOf(context).top : 0,
        ),
        child: Column(
          children: [
            if (!_showLyrics && _tab == 0) _buildSearchBar(),
            // 有输入时给输入联想(原版交互); 历史/热词在搜索落地页里
            if (!_showLyrics && _tab == 0 && _exact != null)
              SearchExactBar(
                view: _exactView(_exact!),
                onPickArtist: _openExactArtist,
                onPickPlaylist: _openExactPlaylist,
                onPickRadio: _openExactRadio,
              ),
            if (!_showLyrics &&
                _tab == 0 &&
                _suggestions.isEmpty &&
                _exact == null &&
                _keywordSuggestions.isNotEmpty)
              KeywordSuggestBar(
                keywords: _keywordSuggestions,
                onSelected: _searchKeyword,
              ),
            if (!_showLyrics && _tab == 0 && _error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    if (_retryLast != null)
                      TextButton(
                        onPressed: () {
                          final retry = _retryLast;
                          setState(() => _error = null);
                          retry?.call();
                        },
                        child: const Text('重试'),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  // 歌词页盖在上面时 tab 树仍然存活(Offstage), 收起歌词不重建、不闪图
                  Positioned.fill(
                    child: Offstage(
                      offstage: _showLyrics,
                      child: _buildTabPages(),
                    ),
                  ),
                  if (_showLyrics)
                    // 背景色由当前曲目封面取色, 无彩/取色失败时完全透明直通主题
                    Positioned.fill(
                      child: CoverBackdrop(
                        palette: _coverPalette,
                        child: _buildLyrics(),
                      ),
                    ),
                  // 输入联想盖在 tab 内容之上并**占满剩余高度**(需求 14):
                  // 以前它是一条 maxHeight 280 的窄条, 联想多了只能在小矩形里滚,
                  // 下面还露出半截结果页。tab 树仍然挂在 Offstage 里, 收起联想不重建。
                  if (!_showLyrics && _tab == 0 && _suggestions.isNotEmpty)
                    Positioned.fill(
                      // 不透明底色: 联想面板铺满后, 下面的 tab 内容不该从卡片外边
                      // 那 12dp 的缝里透出来。
                      child: ColoredBox(
                        color: Theme.of(context).colorScheme.surface,
                        child: SuggestionPanel(
                          items: _suggestions,
                          onSelected: (item) => _searchKeyword(item.title),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onTabSelected(int index) {
    if (_tab == index) return;
    _tabVisited.add(index);
    // 切 tab 一律收起歌词: 否则歌词页会一直占着焦点, 切过去看不到目标页面
    final wasLyrics = _showLyrics;
    setState(() {
      _tab = index;
      _searchFocus.unfocus();
      _showLyrics = false;
    });
    _lyricTicker?.cancel();
    _lyricTicker = null;
    // 回到搜索: 按设置决定是否丢弃上一次的输入/结果/错误
    if (index == 0) {
      if (AppSettings.instance.clearSearchOnTabSwitch &&
          (wasLyrics ||
              _controller.text.isNotEmpty ||
              _bundle != null ||
              _libraryTitle != null ||
              _error != null)) {
        _clearSearch();
      }
      _loadSearchHistory();
    }
  }

  /// 五个 tab 都塞进 IndexedStack(访问过的才真正构建), 保留各自的 State.

  /// 顶部栏: **只在它承载了导航里没有的信息时才出现**。
  ///
  /// - 歌词页: 曲名 + 收起按钮;
  /// - 歌单/正在播放/心动模式的浏览态: 当前列表名 + 返回按钮;
  /// - 其它情况(含「搜索」tab 首页、「推荐/关注/我的/设置」): **整条 AppBar 不出现**。
  ///   两处理由: ①这四页标题原本就是底部导航标签, 完全重复;
  ///   ②搜索页顶部的品牌横幅只是装饰, 用户明确要求去掉 —— 省下的 56dp 全给内容。
  ///   没有 AppBar 时也不再有顶部「登录」动作: 未登录引导在「我的」页(mine_view 的登录按钮)
  ///   与资料头点击(审查 P1-7.10 已定: 账号入口 3→1)。
  PreferredSizeWidget? _buildTopBar(
    BuildContext context,
    rust.SongDto? current,
  ) {
    final showBar = _showLyrics || _libraryTitle != null;
    if (!showBar) return null;
    return AppBar(
      // 大字号 + 动作图标会把默认 22sp 的标题挤成 "轻音 Mi…"(vivo 1440px 实测),
      // 标题固定用 titleMedium, 让品牌字至少完整显示
      // 详情页(歌词页)标题: 保留 titleLarge 的字重观感, 但显式 20sp + height 1.25。
      // 22sp 默认行高下中文歌名在 56dp AppBar 里下半段会被裁掉(用户反馈);
      // 20sp 仍明显大于 titleMedium(16sp), 不会退回"字号特别小"。
      titleTextStyle: Theme.of(context).textTheme.titleLarge
          ?.copyWith(fontSize: 20, height: 1.25, fontWeight: FontWeight.w600),
      // 长歌名横向滚动播放(marquee); 放不下不再 FittedBox 缩成小字
      title: MarqueeText(
        _showLyrics
            ? (_lyricSelecting
                  ? '已选 ${_selectedLyricLines.length} 句'
                  : (current?.name ?? '歌词'))
            : (_libraryTitle ?? '轻音 MiniNCM'),
      ),
      leading: _showLyrics
          ? IconButton(
              icon: const Icon(Icons.expand_more),
              tooltip: '收起歌词',
              onPressed: _toggleLyrics,
            )
          : (_libraryTitle != null
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: '返回搜索',
                    onPressed: _closeLibrary,
                  )
                : null),
      actions: [
        // 歌曲详情页(歌词页)的右上角: 分享 / 翻译开关 / "..." 菜单
        if (_showLyrics) ...[
          if (_lyricSelecting) ...[
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享所选歌词',
              onPressed: _shareSelectedLyrics,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '取消选择',
              onPressed: _clearLyricSelection,
            ),
          ] else ...[
            // 翻译开关已挪到歌词右下角(「定位当前歌词」上方), 见 _buildLyrics.
            // "..." 从播放条挪到详情页里(播放条只留播放控制)
            if (current != null)
              SongOverflowButton(
                song: current,
                size: 22,
                // 队列来源即菜单来源: 日推/FM 才显示"不感兴趣"
                source: _playSource,
              ),
            IconButton(
              icon: const Icon(Icons.share),
              tooltip: '分享这首歌',
              onPressed: () => _shareSong(),
            ),
          ],
        ] else if (_auth.isAndroid && _info?.loggedIn != true)
          // 登录(WebView)只在安卓端(桌面版还没有网页登录宿主)。
          // 审查 P1-7.10: 账号入口 3→1 —— 账号簿/切换/退出登录统一走「我的」页资料头。
          TextButton.icon(
            onPressed: _login,
            icon: const Icon(Icons.login, size: 18),
            label: const Text('登录'),
          ),
      ],
    );
  }

  Widget _buildTabPages() {
    return IndexedStack(
      index: _tab,
      children: [
        for (var i = 0; i < 5; i++)
          if (_tabVisited.contains(i))
            _buildTabPage(i)
          else
            const SizedBox.shrink(),
      ],
    );
  }

  Widget _buildTabPage(int index) {
    switch (index) {
      case 1:
        return RecommendView(
          key: ValueKey('recommend-${_info?.loggedIn}-${_info?.vip}'),
          loggedIn: _info?.loggedIn == true,
          // 每日推荐歌单走本地缓存(同一天只拉一次; 设置里可关/改保留天数)
          loadDailyPlaylists: _dailyPlaylists,
          onPlaySongs: _playSongsList,
          onOpenPlaylist: _openPlaylist,
          onOpenPodcast: _openPodcastRadio,
          onHeartMode: () => _heartMode(),
          onOpenDaily: _openDiscover,
          onPlayFm: (songs, index) =>
              _playSongsList(songs, index, source: SongActionSource.personalFm),
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
            onPlay: _playSongsList,
          ),
          onOpenNewRelease: () => showNewReleasePage(
            context,
            onPlaySongs: _playSongsList,
            onOpenAlbum: (album) => showAlbumPreview(
              context,
              albumId: album.id,
              albumName: album.name,
              coverUrl: album.coverUrl,
              onPlay: _playSongsList,
            ),
            onOpenArtist: (artist) => showArtistDetail(
              context,
              artistId: artist.id,
              name: artist.name,
              onPlaySongs: (songs, i) => _playSongsList(songs, i),
              onOpenAlbum: (id, name, cover) => showAlbumPreview(
                context,
                albumId: id,
                albumName: name,
                coverUrl: cover,
                onPlay: (songs, i) => _playSongsList(songs, i),
              ),
            ),
          ),
        );
      case 2:
        return FeedView(
          key: ValueKey('feed-${_info?.loggedIn}'),
          loggedIn: _info?.loggedIn == true,
          onLogin: _login,
          onPlaySongs: _playSongsList,
          onOpenUrl: PlatformBridge.openUrl,
        );
      case 3:
        return MineView(
          key: ValueKey('mine-${_info?.loggedIn}-${_info?.vip}'),
          loggedIn: _info?.loggedIn == true,
          onLogin: _login,
          onOpenAccounts: _openAccountPage,
          onPlaySongs: _playSongsList,
          onOpenPlaylist: _openPlaylist,
          onOpenPodcast: _openPodcastRadio,
          onOpenFollows: () => _openUserList(startOnFans: false),
          onOpenFolloweds: () => _openUserList(startOnFans: true),
          onOpenAlbum: (album) => showAlbumPreview(
            context,
            albumId: album.id,
            albumName: album.name,
            coverUrl: album.coverUrl,
            onPlay: _playSongsList,
            initiallySubscribed: true,
          ),
          onOpenRecent: _openRecent,
          onOpenLiked: _openLikedDetail,
          onOpenMessages: () => showMessagesPage(context),
          onOpenMedals: () => showMedalWall(context, isVip: _info?.vip == true),
          onOpenVip: _openVip,
          onPlayLiked: (songs, i) =>
              _playSongsList(songs, i, playlistId: _likedPlaylistId),
          // 简介保存: POST /api/user/profile/update(局部更新, 只改 signature)
          saveSignature: (signature) =>
              rust.updateSignature(signature: signature),
        );
      case 4:
        // 设置只剩下「App 怎么表现」的偏好开关 + 分组入口:
        // 账号管理、诊断与数据都是这里的二级页(账号入口 2026-11 统一收在这里)。
        return SettingsView(info: _info, onOpenAccounts: _openAccountPage);
      default:
        return _buildSearchTab();
    }
  }

  Widget _buildSearchTab() {
    final query = _controller.text.trim();
    // 歌单浏览态优先(从我的/推荐点进来的)
    if (_libraryTitle != null) return _buildList();
    // 有上一轮结果就展示分区结果; 取消按钮会清空它
    if (_bundle != null) return _buildSearchResults();
    // 没输入关键词时: 搜索历史 + 猜你想搜 + 热门榜
    if (query.isEmpty) {
      return SearchLanding(
        history: _searchHistory,
        hot: _hotTerms,
        recommended: _recommendedKeyword,
        recommendedReason: _recommendedReason,
        onSelected: _searchKeyword,
        onClearHistory: _clearSearchHistory,
        hotLoading: _hotLoading,
        hotError: _hotError,
        onRetryHot: _loadSearchLanding,
        // 排行榜从「推荐」搬到这里(2026-11 用户要求)
        onOpenChartPlaylist: _openPlaylist,
      );
    }
    return _buildList();
  }

  /// 综合搜索结果: 单曲/艺人/专辑/歌单/播客分区
  Widget _buildSearchResults() {
    return SearchResultsView(
      bundle: _bundle!,
      // 后端 cloudsearch type=1004 的 MV 结果 → UI 的 SearchMv(同构映射)
      mvs: [
        for (final m in _bundle!.mvs)
          SearchMv(
            id: m.id,
            name: m.name,
            coverUrl: m.coverUrl,
            artistName: m.artistName,
            playCount: m.playCount,
          ),
      ],
      liked: _liked,
      currentTrackId: _current?.id,
      onPlaySong: _playFromSearch,
      onOpenArtist: _openSearchArtist,
      onOpenAlbum: _openSearchAlbum,
      onOpenPlaylist: _openSearchPlaylist,
      onOpenPodcast: _openSearchPodcast,
      onMenu: (song) => showSongActionsSheet(
        context,
        song,
        _buildActionsHost(),
        // 综合搜索结果里的单曲
        source: SongActionSource.search,
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _searchFocus,
              decoration: InputDecoration(
                labelText: '搜索',
                border: const OutlineInputBorder(),
                isDense: true,
                // 输入过东西或已有结果时给一个显式的清空按钮
                suffixIcon: (_controller.text.isEmpty && _bundle == null)
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: _clearSearch,
                      ),
              ),
              textInputAction: TextInputAction.search,
              onChanged: _onQueryChanged,
              onSubmitted: (_) => _search(),
            ),
          ),
          const SizedBox(width: 8),
          // 不再并排放「取消」: 它与输入框里的清空 suffix 是同一个动作
          // (_clearSearch), 两个同义按钮只会让人不知道该按哪个(审查 P1-7.4)
          FilledButton(
            onPressed: _busy ? null : _search,
            child: Text(_busy ? '搜索中' : '搜索'),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    final current = _current;
    if (_libraryTitle == null) {
      // 搜索请求还没回来时给加载占位: 原来的"输入关键词后搜索"会让用户
      // 以为断网或没有结果(本次回归修复)。错误由顶部横幅展示(带重试)。
      if (_busy) return SearchLoading(_controller.text.trim());
      if (_error != null) return const SizedBox.shrink();
      final typed = _controller.text.trim();
      if (typed.isEmpty) {
        return const Center(child: Text('输入关键词后搜索'));
      }
      // 已经输入但还没提交: 上方是联想面板, 这里给一句明确的操作提示
      return Center(
        child: Text(
          '点「搜索」查看「$typed」的结果',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final songs = _visibleSongs;
    final hidden = _hiddenUnplayable;
    if (songs.isEmpty) {
      return Center(
        child: Text(hidden > 0 ? '这里没有可播放的曲目($hidden 首无版权已隐藏)' : '这个歌单是空的'),
      );
    }
    // 列表顶部一句说明: 无版权且没收藏的曲目按官方行为直接不出现, 但要让用户知道少了什么
    final headerCount = hidden > 0 ? 1 : 0;
    return ListView.builder(
      itemCount: songs.length + headerCount,
      itemBuilder: (context, i) {
        if (headerCount == 1 && i == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              '已隐藏 $hidden 首无版权曲目',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        }
        final s = songs[i - headerCount];
        final active = current?.id == s.id;
        // 没版权: 整行灰掉 + "无版权"标, 点了才提示(官方同款行为)
        return SongTile(
          song: s,
          active: active,
          liked: _isLiked(s.id),
          onTap: () {
            if (s.playable) {
              _playFromList(s);
            } else {
              _notifyUnplayable(s);
            }
          },
          onMenu: () => showSongActionsSheet(
            context,
            s,
            _buildActionsHost(),
            // 库内歌单/列表详情
            source: SongActionSource.playlist,
          ),
        );
      },
    );
  }

  /// 歌曲详情页正文 = 歌词 + (定位当前句 / 底部次要控制)
  Widget _buildLyrics() {
    // 多选态: 点行 = 加/减选; 非多选态点击不做事(避免误改焦点)
    final onTap = _lyricSelecting ? (int i) => _selectLyricLine(i) : null;
    final onLong = _selectLyricLine;
    final showTranslation = AppSettings.instance.lyricTranslation;

    final Widget body;
    if (_wordLines.isNotEmpty) {
      body = WordLyricView(
        lines: _wordLines,
        positionMs: _wordPositionMs,
        playing: _playing,
        controller: _lyricScroll,
        itemExtent: _lyricItemExtent,
        showTranslation: showTranslation,
        selected: _selectedLyricLines,
        onLineTap: onTap,
        onLineLongPress: onLong,
        autoScroll: _autoFollowLyric,
      );
    } else if (_lyricPlain != null) {
      body = PlainLyricView(
        lines: _lyricPlain!,
        controller: _lyricScroll,
        selected: _selectedLyricLines,
        onLineTap: onTap,
        onLineLongPress: onLong,
      );
    } else if (_lyricError != null) {
      body = Padding(
        padding: const EdgeInsets.all(24),
        child: Center(child: Text(_lyricError!, textAlign: TextAlign.center)),
      );
    } else if (_lyricLines.isEmpty) {
      body = const Center(child: Text('暂无歌词'));
    } else {
      body = TimedLyricView(
        lines: _lyricLines,
        activeIndex: _lyricIndex,
        controller: _lyricScroll,
        itemExtent: _lyricItemExtent,
        showTranslation: showTranslation,
        selected: _selectedLyricLines,
        onLineTap: onTap,
        onLineLongPress: onLong,
      );
    }

    return Column(
      children: [
        Expanded(
          child: NotificationListener<ScrollNotification>(
            onNotification: (n) {
              // 只认"手指拖动启动"(ScrollStartNotification.dragDetails != null):
              // - 这个 NotificationListener 只包住歌词列表, 子树里能带 dragDetails 的
              //   ScrollStart 只可能来自列表自身的拖动(播放条/进度条在子树外);
              // - 自动跟随的 animateTo 发出的 ScrollStart/ScrollUpdate 都没有
              //   dragDetails, 不会被误判成用户滑动.
              if (n is ScrollStartNotification && n.dragDetails != null) {
                _pauseLyricFollow();
              }
              return false;
            },
            child: Stack(
              children: [
                Positioned.fill(child: body),
                // 曾经在这里常驻一行"逐字歌词 · 网易云"来源小字(左下角),
                // 用户反馈那是一条像水印的文本框, 已去掉(2026-11)。
                // 打分/择优的实现与单测仍在 lyricSourceLabel / scoreWordLyric.

                // 右下角竖排: 翻译开关在上, 定位当前歌词在下(用户要求把顶部翻译
                // 开关挪到侧面). 歌词本身没有 tlyric 时不出现翻译键.
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_hasLyricTranslation)
                        IconButton.filledTonal(
                          tooltip: AppSettings.instance.lyricTranslation
                              ? '关闭翻译'
                              : '显示翻译',
                          icon: Icon(
                            Icons.translate,
                            size: 20,
                            color: AppSettings.instance.lyricTranslation
                                ? Theme.of(context).colorScheme.primary
                                : null,
                          ),
                          onPressed: _toggleLyricTranslation,
                        ),
                      if (_hasLyricTranslation) const SizedBox(height: 8),
                      IconButton.filledTonal(
                        tooltip: '定位到当前歌词',
                        icon: const Icon(Icons.my_location, size: 20),
                        onPressed: _locateCurrentLyric,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 投递播放条数据快照(帧后; 与上一份相等时 ValueNotifier 不通知 → 播放条不重建)。
  ///
  /// 没有曲目时不投(Media3 连接前拿到的是一份空状态, 空态不占位置)。
  void _publishPlayerBar(PlayerView? player, rust.SongDto? current) {
    final showBar =
        player != null && (player.trackId != null || current != null);
    final PlayerBarData? data = !showBar
        ? null
        : PlayerBarData(
            player: player,
            current: current,
            liked: _isLiked(current?.id),
            queueIndex: _queue.isEmpty ? 1 : _queue.index + 1,
            queueLength: _queue.items.length,
            dragMax: _dragMax,
            dragMs: _dragMs,
            mode: _queue.mode,
            heartActive: _heartActive,
          );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => playerBarData.value = data,
    );
  }

  /// 首页底部导航栏的构建结果, 由根布局渲染(见 [playerBarSlot])。
  ///
  /// 底部 tab 属于首页: 有全屏页压在首页之上时返回 null(播放条由
  /// [playerBarData] 负责, 此时它自己吃掉系统手势区), 弹层/对话框不算。
  Widget? _buildBottomBar() {
    if (_pageDepth.value > 1) return null;
    return NavigationBar(
      selectedIndex: _tab,
      onDestinationSelected: _onTabSelected,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.search_outlined),
          selectedIcon: Icon(Icons.search),
          label: '搜索',
        ),
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: '推荐',
        ),
        NavigationDestination(
          icon: Icon(Icons.dynamic_feed_outlined),
          selectedIcon: Icon(Icons.dynamic_feed),
          label: '关注',
        ),
        NavigationDestination(
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: '我的',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '设置',
        ),
      ],
    );
  }
}
