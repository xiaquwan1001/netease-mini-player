import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import 'app_settings.dart';
import 'home/home_page.dart' show HomePage;
import 'layout.dart' show ContentWidthLimit, kRailWidth;
import 'lifecycle_guard.dart' show runPostFrameIfAlive;
import 'now_playing.dart' show nowPlayingSongId;
import 'player_bar.dart';
import 'popup_routes.dart' show dismissPopupRoute;
import 'song_actions.dart';
import 'theme.dart';
import 'toast.dart';

// 全局壳: 动作宿主/页面层数/常驻底部条槽位 + 根 Overlay + MaterialApp 装配。
// 从 main.dart 原样搬出(2026-11 拆壳 S1), 行为/时序/文案零改动。
//
// **全局槽位只许在本文件(或 home/home_wiring.dart)里写**: 这里每个 publish* 都是
// "帧后 + 存活守卫"的唯一写入口, 门禁 tools/check-global-slots.sh 会拦住别的文件
// 直接 `xxxSlot.value = ...`(审计 7.6)。
//
// 跨文件符号: `_actionsHost`/`_pageDepth`/`_publishBottomBar` 在
// src/home/home_page.dart 的 _HomePageState 里被直接读写, 而 Dart 的私有成员不跨库,
// 所以这里保留单一实例但改成公共名(不复制状态、不加 getter 包装), 只对它暴露。
// 其余(Observer/壳内部 State/Chrome)仍为私有。
//
// 与 home_page.dart 互相 import(Dart 允许环): MiniNcmApp.home 是 HomePage,
// 而 HomePage 要读这里的槽位/投递函数; 顶层 final 惰性初始化, 无初始化顺序问题。

/// 应用级滚动行为: **桌面也能拖动列表**。
///
/// Flutter 默认的 [ScrollBehavior.dragDevices] 只有 touch —— 桌面(鼠标/触控板)
/// 既拖不动列表, 也就永远触发不了 RefreshIndicator(它的 overscroll 判定只认
/// 拖动)。用户 2026-11-18: "Linux 桌面没有下拉刷新触发逻辑, 要补: 拖拽下拉"。
/// 放开四种指针后, 手指/鼠标/触控板/手写笔的拖动语义完全一致:
/// 列表能滚就滚, 已到顶还继续下拉就是刷新(RefreshIndicator 原有逻辑)。
///
/// 滚轮这一路不走拖动, 见 WheelRefreshable(每个可刷新列表自己包)。
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const <PointerDeviceKind>{
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
  };
}

/// 全局动作回调宿主: MaterialApp.builder 里包一层 AppActions,
/// 这样搜索结果/详情页/底部面板等所有路由里的 "..." 菜单都能拿到同一套回调。
final ValueNotifier<SongActionHost?> actionsHost =
    ValueNotifier<SongActionHost?>(null);

/// 根导航栈里"全屏页"的层数(弹层/对话框不算一层): 1 = 只有首页.
///
/// 底部 tab 属于首页, 有全屏页压上来时让位; 若按 [ModalRoute.isCurrent] 判断,
/// 弹一个底部面板(PopupRoute)也会让底部导航消失, 所以这里只数非弹层路由。
///
/// 初值 0 而不是 1: 首页这条路由本身也会走 didPush(变成 1); 而手工 pump HomePage
/// 的单测里没有观察者, 值停在 0 —— 两者都满足 "<= 1 就是首页在栈顶"。
final ValueNotifier<int> pageDepth = ValueNotifier<int>(0);

/// 有弹层(PopupRoute: 底部面板/对话框)压着时为 true。
///
/// 只给宽屏的 [ContentWidthLimit] 用: 限宽盒在 Navigator **外面**, 弹层的
/// `ModalBarrier` 因此也只有 840 宽(1280 窗口下两侧留白是亮的) —— 壳层据此把留白
/// 按遮罩同色压暗, 视觉上连续。**不改变**任何点击/让位语义(播放条/导航栏在弹层期间
/// 仍可点, 与改动前一致)。
final ValueNotifier<bool> modalRouteOpen = ValueNotifier<bool>(false);

/// NavigatorObserver: 维护 [pageDepth](栈里非弹层路由的层数)与 [modalRouteOpen].
class NcmRouteObserver extends NavigatorObserver {
  /// 当前压着的弹层路由(PopupRoute), **栈序: 底 → 顶**。
  ///
  /// 不只数个数: 收起浮层时必须能指名「关掉哪一条」—— 关"栈顶"的 `maybePop()`
  /// 在浮层之上又压了一层时会关错(队列面板上的「清空确认框」, U-02)。
  /// 登记表只记 route 本身, 当前/活跃状态交给 route 自己的 `isCurrent`/`isActive`。
  static final List<PopupRoute<dynamic>> _popups = <PopupRoute<dynamic>>[];

  static void _popupUp(PopupRoute<dynamic> route) {
    _popups.add(route);
    modalRouteOpen.value = true;
  }

  static void _popupDown(PopupRoute<dynamic> route) {
    _popups.remove(route);
    if (_popups.isEmpty) modalRouteOpen.value = false;
  }

  static void _up() {
    if (pageDepth.value < 1) {
      pageDepth.value = 1;
    } else {
      pageDepth.value = pageDepth.value + 1;
    }
  }

  static void _down() {
    pageDepth.value = pageDepth.value > 1 ? pageDepth.value - 1 : 1;
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _popupUp(route);
      return;
    }
    _up();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _popupDown(route);
      return;
    }
    _down();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) {
      _popupDown(route);
      return;
    }
    _down();
  }

  /// `pushReplacement` / `Navigator.replace` 的钩子(U-07)。
  ///
  /// 替换**既不是 push 也不是 pop**: 不接这一路的话, 被换掉那条的账永远收不回来 —
  /// 用 `pushReplacement` 把一层全屏页换成弹层, [pageDepth] 就永久停在 2
  /// (底部导航再也不出现); 把弹层换成全屏页, [modalRouteOpen] 就永久 true
  /// (宽屏两侧留白一直压暗), 而且 [NcmRouteObserver._popups] 还留着死 route,
  /// [dismissAllPopups] 会去关一条已经不在栈上的浮层。
  ///
  /// 口径与 push/pop 完全一致: 按"先摘旧的、再挂新的"记账。净效果:
  /// 全屏↔全屏 层数不变, 全屏→弹层 层数 -1 且并入弹层登记表, 弹层→全屏 反之。
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      if (oldRoute is PopupRoute) {
        _popupDown(oldRoute);
      } else {
        _down();
      }
    }
    if (newRoute != null) {
      if (newRoute is PopupRoute) {
        _popupUp(newRoute);
      } else {
        _up();
      }
    }
  }
}

/// 根 Navigator 上当前压着的浮层(栈序: 底 → 顶)的只读快照。排查/测试用。
List<PopupRoute<dynamic>> get openPopups =>
    List<PopupRoute<dynamic>>.unmodifiable(NcmRouteObserver._popups);

/// **关闭所有浮层**(底部面板 / 对话框)—— 切底部 tab 的唯一入口。返回关掉的条数。
///
/// 为什么需要它: 底部导航住在 Navigator **之外**, 弹层开着时仍然可点; 而弹层是
/// modal route, 不会随 tab 切换自己消失, 会一直挂在旧页面上(用户 2026-11-17 登录弹层 /
/// 2026-11-18 队列面板反馈)。以前在 `_onTabSelected` 里逐类手写
/// (`dismissLoginSheet()` + `_queueUI.close()`), 只补了 2 类, 实测漏 5 类
/// (歌曲动作面板 / 收藏到歌单 / 分享面板 / 关注页艺人筛选 / 更新弹窗)。
///
/// 现在按 `NcmRouteObserver` 的登记表逐条关: 是 sheet 还是 dialog 不重要, 只要是
/// `PopupRoute` 就被收掉。栈顶那条走 `pop()`(带动画), 被压在下面的直接 `removeRoute`。
int dismissAllPopups() {
  final routes = List<PopupRoute<dynamic>>.of(NcmRouteObserver._popups);
  if (routes.isEmpty) return 0;
  var closed = 0;
  // 从栈顶往下: 先关上面那条, 下面那条随即变成 current
  for (final route in routes.reversed) {
    if (dismissPopupRoute(route)) closed += 1;
  }
  return closed;
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
///
/// [context] 是给"帧后回调"用的存活判据(U-05): 首页在两次构建之间被销毁时,
/// 它的旧导航栏(以及旧闭包)不能再写进全局槽位, 见 [runPostFrameIfAlive]。
void publishBottomBar(BuildContext context, Widget? bar) {
  runPostFrameIfAlive(context, () => playerBarSlot.value = bar);
}

/// 投递全局动作宿主([actionsHost] 的**唯一写入口**)。
///
/// 与 [publishBottomBar] 同口径(帧后 + [BuildContext.mounted] 判据): 宿主是页面
/// 生成的一束菜单回调, 页面销毁后它的闭包还指着死页面的 State —— 之后再点 "..."
/// 就是在已销毁实例上 setState。原先两处(home_page 的启动与"重建宿主"回调)各自
/// 直接写槽位, 靠人记守卫; 收口到本函数后漏写就编译不到全局槽位(见
/// tools/check-global-slots.sh)。
void publishActionsHost(BuildContext context, SongActionHost? host) {
  runPostFrameIfAlive(context, () => actionsHost.value = host);
}

/// 投递播放条数据快照 + 全局"正在播放"样本([playerBarData] / [nowPlayingSongId]
/// 的**唯一写入口**)。
///
/// 两者必须落在**同一个**帧后回调里(顺序: 快照 → 高亮), 与拆分前一致; 拆成两次
/// 投递会让同一帧里多出一次通知。帧后 + 存活判据同 [publishBottomBar]: 首页在这一帧
/// 之后被销毁时, 旧实例的数据/播放态不准再写进全局槽位。
void publishPlayerBarSnapshot(
  BuildContext context, {
  required PlayerBarData? data,
  required BigInt? nowPlayingId,
}) {
  runPostFrameIfAlive(context, () {
    playerBarData.value = data;
    nowPlayingSongId.value = nowPlayingId;
  });
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
              // 宽档导航: HomePage 投递 NavigationRail 时, 壳层把它挂到**左侧**
              // (见下), 其余一切的"底部条"假设不变。判据只用 widget 类型:
              // 投递方(HomePage)按 MediaQuery 宽度决定投哪一种, 壳层不重复算档位。
              final rail = navBar is NavigationRail ? navBar : null;
              final bar = (data == null || actions == null || keyboardUp)
                  ? null
                  // 没有「底部」导航(含宽档的左侧 Rail)时播放条自己吃掉系统手势区:
                  // 宽档下没人替它吃, 不传 true 会贴不到屏幕底边。
                  : MiniPlayerBar(
                      data: data,
                      actions: actions,
                      absorbBottomInset: navBar == null || rail != null,
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
              // 键盘弹出时底部导航也一起让位(2026-11-14 用户反馈 4/6):
              // 搜索联想面板下方总有一段"跟随输入法出现"的空缺, 高度≈底部导航栏,
              // 因为 HomePage 的 Scaffold 已经按 viewInsets.bottom 收缩过一次,
              // 而导航栏还占着根 Column 的 80dp ⇒ 内容底边 = 键盘顶 - 80dp。
              // 键盘在场时导航栏本来就被键盘挡住, 一并隐藏后缺口消失。
              // 宽档的 Rail 不走这段(它没有底部/状态栏两条 inset 的问题,
              // 由上面的 rail 分支单独挂载, 自己带 SafeArea)。
              final nav = navBar == null || keyboardUp || rail != null
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
              // 宽屏内容限宽(lane/ui-adaptive P2): 可用宽 > kContentMaxWidth 时
              // 内容居中限宽, 两侧留出与 Scaffold 同色的空白。窄屏/中屏完全不插入
              // widget(几何零变化) —— 见 layout.dart 的 ContentWidthLimit。
              // 只包 body(Navigator), 播放条与导航栏保持通栏。
              final content = Expanded(
                child: ContentWidthLimit(
                  // 弹层在场时两侧留白跟着遮罩压暗(见 layout.dart 的
                  // kContentGapBarrierColor 与该文件的「已知边界」)
                  dimmedGaps: modalRouteOpen,
                  child: body,
                ),
              );
              final column = Column(children: [content, ?bar, ?nav]);
              if (rail == null || keyboardUp) return column;
              // 宽档: 左侧导航栏占满整列高度(含播放条那一行), 内容/播放条在右侧列。
              // Row 必须 stretch: NavigationRail 内部有 Flexible, 松高度会报
              // "non-zero flex but incoming height constraints are unbounded"。
              // 顶部/底部安全区由 SafeArea 给(Rail 自己只处理左右),
              // 否则安卓横屏第一条目的地会压在状态栏下。
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SafeArea(
                    left: false,
                    right: false,
                    child: SizedBox(width: kRailWidth, child: rail),
                  ),
                  Expanded(child: column),
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
    // 只订阅**外观**域: 主题色/OLED/字号是这里唯一吃的东西。
    // 旧写法(AnimatedBuilder on AppSettings.instance)订阅全体通知, 音量滑块每拖一格
    // 都会把整个 MaterialApp 连同整棵树重建一遍(§12.6 第二步的痛点)。
    return AppSettingsScopedBuilder(
      domains: const {AppSettingsDomain.appearance},
      builder: (context) {
        final settings = AppSettings.instance;
        return MaterialApp(
          title: '轻音 MiniNCM',
          // 桌面也能拖动滚动(见 [AppScrollBehavior]): 下拉刷新才不会只在手机上可用
          scrollBehavior: const AppScrollBehavior(),
          // 根 messenger: 播放/调音管线的后台失败没有 BuildContext, 靠它提示
          // (见 src/toast.dart 的 showGlobalToast)。
          scaffoldMessengerKey: rootMessengerKey,
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
              valueListenable: actionsHost,
              builder: (_, host, inner) =>
                  host == null ? inner! : AppActions(host: host, child: inner!),
              child: PlayerBarHost(content: child ?? const SizedBox.shrink()),
            ),
          ),
          // 只用来数"有没有全屏页压在首页上"(决定底部 tab 是否让位)
          navigatorObservers: [NcmRouteObserver()],
          home: const HomePage(),
        );
      },
    );
  }
}
