# UI 层浮层 / 切换钩子 / 返回栈 / 生命周期 架构评估 — 2026-11-18

> **只读审计, 不改产品代码, 不跑构建**。方法: `rg`/`sed -n`/`wc -l` 静态分析 + 定点精读;
> 未跑 `flutter test`/`cargo test`/`gradle`/`ci-gates.sh verify`(硬约束)。
> 门禁数字**抄自 `docs/PROGRESS.md` 头部「当前门禁」表**(Rust **313** / Dart **1123** / golden 18 / analyze 0 / clippy 0);
> 本文件里凡是"本机实测"的数字都注明了 `rg` 命令(rg 逐行计数 = 出现次数, 不是文件数)。
> 与派发线索不一致的地方全部列在 §0.2, 以本文件为准。

## 状态: 已完成 (9/9 问)

## 0.1 行号口径声明(重要, 先读)

1. **行号是「工作树」快照, 不是 commit `5b79e5a`。** 审计开始时工作树已带着另一条在飞车道(`lane/ui-adaptive`)的未提交改动,
   **审计过程中它还在继续改**(`ui/lib/src/app_shell.dart` 的 diff 在审计期间从 +38 行变成 +87 行, `main.dart`/`layout.dart` 也动了)。
   实测 `git diff --stat`(审计末尾): `app_shell.dart` +87 / `home_page.dart` +49 / `layout.dart` +122 / `main.dart` +2,
   新增 `ui/test/{content_width_limit,layout_breakpoints,nav_rail_shell}_test.dart` + `ui/test/support/nav_chrome.dart`; 另有 `docs/` 8 个文件改动(另一条车道)。
2. 本次审计**只读**: 未编辑任何产品代码/测试/其它文档; 产物只有本文件。
3. 因为树在动, **每条结论都绑了符号名**, 行号只当提示:

| 符号 | 当前行 | 说明 |
|---|---|---|
| `pageDepth` / `modalRouteOpen` | `app_shell.dart:37` / `:43` | 两个 "栈状态" `ValueNotifier` |
| `NcmRouteObserver`(原 `_PageDepthObserver`, 审计期间改名公开) | `app_shell.dart:46` | 唯一的 `NavigatorObserver`(含弹层计数) |
| `publishBottomBar` | `app_shell.dart:122` | 底部条帧后投递(无 mounted 守卫) |
| `PlayerBarHost` / `_entry` / `Overlay` | `app_shell.dart:134` / `:147` / `:159` | 根 Overlay 宿主 |
| `_PlayerBarChrome` | `app_shell.dart:162` | 键盘让位/安全区/rail 分支 |
| `keyboardUp` / `rail` / `absorbBottomInset` / `nav` / `column` / `Row` | `app_shell.dart:170` / `:183` / `:191` / `:209` / `:236` / `:243` | 布局判据 |
| `AnimatedBuilder(AppSettings)` / `scaffoldMessengerKey` | `app_shell.dart:267` / `:275` | 主题继承 / 根 messenger |
| `_onTabSelected` / `dismissLoginSheet()` / `_queueUI.close()` | `home_page.dart:1095` / `:1099` / `:1103` | 唯一的"切 tab 收起"清单 |
| `_buildBottomBar` / `NavigationRail` / `NavigationBar` | `home_page.dart:1623` / `:1630` / `:1667` | 导航档位 |
| `_publishPlayerBar` / `publishBottomBar(...)` | `home_page.dart:1594` / `:994` | 帧后投递入口 |
| `popUntil(isFirst)` | `home_page.dart:285` / `:292` | 播放条回首页 |
| `HomeBackGuard` / `resolveHomeBackAction` | `back_policy.dart:31` / `:16` | 根返回键 |
| `HomeWiring._latest` / `attach` / `detach` | `home_wiring.dart:75` / `:81` / `:112` | 进程级钩子配对 |
| `QueueSheetController.close` / `open` | `queue_sheet_controller.dart:122` / `:143` | 队列面板 |
| `dismissLoginSheet` / `_openLoginRoute` | `login_sheet.dart:671` / `:665` | 登录弹层路由登记 |

## 基线(本机实测 2026-11-18)

| 指标 | 值 | 命令 |
|---|---|---|
| `ui/lib` dart 文件 / 行数 | **153 / 62,944** | `find lib -name '*.dart' -print0 \| xargs -0 wc -l \| tail -1` |
| `showModalBottomSheet` | **22 处 / 17 文件** | `rg -n showModalBottomSheet lib\|wc -l` / `rg -l ...\|wc -l` |
| `showDialog` | **19 处 / 15 文件** | 同上换 `showDialog` |
| 统一 sheet 入口(`showAppSheet` 类) | **0 处** | `rg -n "showAppSheet|showAppDialog" lib` → 无输出 |
| `PopScope` | **2 处** | `back_policy.dart:45`、`history_tab.dart:93` |
| `WillPopScope` / `BackButtonListener` / `NavigatorPopHandler` / `RouteAware` / `didPopNext` | **全 0** | `rg` 全仓(含 test) 无命中 |
| `WidgetsBindingObserver` | **1 个类 / 1 处注册** | `desktop_shell.dart:258`, 在 `home_page.dart:347` 注册 |
| `AppLifecycleListener` / `didChangeAppLifecycleState` | **全 0** | `rg` 无命中 |
| `Navigator.*.push(` / `.pop(` / `maybePop(` | **30 / 71** | `rg -n "\.push\(|\.push<|pushReplacement" lib\|wc -l` 等 |
| `showDragHandle:`(sheet 参数) | **21**(22 命中减 1 处文档注释) | `rg -n showDragHandle lib\|wc -l` = 22, 其中 `queue_sheet_controller.dart:17` 是注释 |
| `SheetHeader(... onClose:` 调用点 | **5**(全仓 `onClose:` 6 命中, 1 条不是 sheet) | `rg -n "onClose:" lib` |

## 0. 结论摘要

**一句话**: 浮层与返回栈的**语义是对的**(返回键一次退一层、根 guard 只在根路由生效、弹层不参与 `pageDepth`),
真正的账在**所有权**: 22 个 sheet 各自 `showModalBottomSheet` + 各自记账, "切 tab 收起"只能在 `_onTabSelected` 里逐处手写;
而导航/播放条住在 Navigator **之外** —— 这既是"二级页也有播放条"的设计底座, 也是"浮层之上还能点 tab"的根因。

| 级 | # | 缺陷 | 成本 | 需真机 |
|---|---|---|---|---|
| **P1** | U-01 | 导航/播放条住在 Navigator 外 ⇒ modal 浮层开着时仍可点 tab; "切 tab 收起"只补了 2 类, 实测**还漏 5 类** | M | 否 |
| **P2** | U-02 | `QueueSheetController.close()` 用 `maybePop()` 弹"栈顶"而非"自己" ⇒ 队列面板上压着确认框时切 tab 只关掉确认框 | S(局部)/M(统一入口后) | 否 |
| **P2** | U-03 | 22 个 sheet 没有统一入口: 拖拽条 21/22、显式关闭键 5、高度口径 3 套、键盘让位只有 5 处手写 | M | 否 |
| **P2** | U-04 | 播 MV 不暂停歌曲、MV Activity 不请求音频焦点 ⇒ 双音源并发(代码事实确定, 听感待真机) | S(暂停)/M(返回恢复) | **是** |
| **P2** | U-05 | `_publishPlayerBar`/`publishBottomBar` 的帧后回调**没有 mounted 守卫** ⇒ 页面销毁后仍往全局槽位写旧闭包 | S | 否 |
| **P2** | U-06 | `HomeWiring._latest` 单指针漏一种组合: A attach → B attach → B detach ⇒ A 还活着但所有进程级钩子已是 null | S | 否(仅多实例) |
| **P3** | U-07 | 栈状态不处理 `didReplace` ⇒ 将来引入 `pushReplacement` 会让 `pageDepth` 永久 +1 / `modalRouteOpen` 永久 true(底部导航消失、留白永远压暗) | S | 否 |
| **P3** | U-08 | `back_policy.dart` 注释承诺"桌面 Esc"退一级, 但全仓没有任何快捷键绑定(注释漂移, 不是缺陷) | S | 否 |
| **P3** | U-09 | `_handleBack` 的 `exitApp → SystemNavigator.pop()` 分支不可达(`canPop` 已放行) | S | 否 |
| **P3** | U-10 | `publishBottomBar` 每次构建都造新 `NavigationBar`/`Rail` ⇒ "内容变了才通知"的注释与实现不符, 每次 HomePage 重建都重造导航 | S | 否 |
| **P3** | U-11 | 缺 `AppLifecycleListener`(全仓 0): 行为上目前**没有可证缺陷**, 只登记形状 | S~M | 否 |
| **P3** | U-12 | `PlayerBarData.==` 用 `identical(current)` 比同一首歌的对象身份 | S | 否 |
| **P3** | U-13 | [rail·在飞车道] 宽档 `NavigationRail` + `ContentWidthLimit` 让"谁吃 inset"/"浮层之上可点导航"/"浮层也被限宽" 三个耦合点又多一处; 新增的 `modalRouteOpen` 是"浮层在场"的**第二份手写记账** | S | 否(需人眼) |

**不建议做**: 引 go_router/auto_route、给所有浮层加"打开即暂停"、统一改造 19 个 dialog、全局拦截桌面 Esc(理由见 §4.3)。

## 0.2 与派发线索的复核差异(以本节为准)

| 线索说法 | 实测 | 证据 |
|---|---|---|
| sheet 22 处 / **20 文件** | 22 处 / **17 文件** | `rg -l showModalBottomSheet lib \| wc -l` = 17 |
| `PopScope` **3 处** | **2 处** | `back_policy.dart:45`、`discover/history_tab.dart:93`; 第三处不存在 |
| `WidgetsBindingObserver` **3 处** | **1 个类 / 1 处注册** | `desktop_shell.dart:258` + `home_page.dart:347`; 全仓 `addObserver` 只有这一处 |
| `TickerProviderStateMixin` **6** | **4 处**(2 个 `TickerProviderStateMixin` + 2 个 `Single...`) | `artist_page.dart:123`、`user_page.dart:85`、`word_lyric_view.dart:431`、`marquee_text.dart:175` |
| `Overlay`/`OverlayEntry` **2/3** | **Overlay 构造 1 处 / OverlayEntry 构造 2 处** | `app_shell.dart:159`(Overlay) + `:147`(entry)、`queue_sheet_controller.dart:308`(toast entry); `:304` 是 `Overlay.maybeOf` 查询 |
| `Navigator.push` **28** / `pop` **40** | **30** / **71** | 命令见基线表; 口径含 `Navigator.push(`/`push<(` 与 `pop(`/`maybePop(` |
| `back_policy` 只覆盖根页面 | ✅ 属实 | `home_page.dart:949-960` 只在 `HomePage.build` 顶层包 `HomeBackGuard` |
| home_wiring 注册 **10 条**钩子 | ✅ 属实(8 类槽位/回调 + 2 条监听, 见 §1.4) | `home_wiring.dart:81-108` |
| 2026-11-18 只补了登录弹层 + 队列面板两处 | ✅ 属实, 且**还漏 5 类**(U-01) | `home_page.dart:1095-1104` |
| `LoginActivity` 已迁 `OnBackPressedDispatcher` | ✅ 属实 | `LoginActivity.kt:44-63` |
| `MvPlayerActivity`/`MainActivity` 返回键待查 | **两者都无误写**: MainActivity 完全没有返回键代码(全交 Flutter); MvPlayerActivity 无 override(默认 finish) | `rg -n "onBackPressed|OnBackPressedCallback" MainActivity.kt MvPlayerActivity.kt` → 无命中 |

## 1. 现状地图

### 1.1 四层"浮层", 三套生命周期

| 层 | 实现 | 数量 | 参与 `pageDepth` | 关闭手段 |
|---|---|---|---|---|
| modal bottom sheet | `showModalBottomSheet`(内部 `ModalBottomSheetRoute extends PopupRoute`) | 22 | **否**(`app_shell.dart:74` `if (route is PopupRoute)` → 只加 `modalRouteOpen`) | 拖拽条(21/22) + 点遮罩 + 返回键 + 关闭键(5) |
| dialog | `showDialog`(`DialogRoute extends PopupRoute`) | 19 | 否(同上) | 屏障点击(除 `cloud_page.dart:210` `barrierDismissible: false`) + 返回键 |
| 无路由浮层 | `OverlayEntry` 手工插栈 | 2(`app_shell.dart:147` 播放条宿主、`queue_sheet_controller.dart:308` 顶部 toast) | 否 | 自管(`Timer 900ms` + `entry.mounted`, `queue_sheet_controller.dart:335-341`) |
| 提示条 | `ScaffoldMessenger` SnackBar(`toast.dart`) | 若干 | 否 | 3s + 横滑; 挂 `rootMessengerKey`(`app_shell.dart:275`) |

### 1.2 22 处 sheet 全清单(`rg -n showModalBottomSheet lib`)

`feed_view_body.dart:242` · `similar_sheet.dart:31` · `cover_quality_sheet.dart:20` · `feed_share.dart:490/504/519` ·
`song_wiki.dart:21` · `comment_thread.dart:538/629` · `detail_shared.dart:19` · `settings_view.dart:817/852` ·
`detail/comments_sheet.dart:28` · `podcast_detail_page.dart:254` · `song_share.dart:261` · `song_actions.dart:159` ·
`digital_album_page.dart:104` · `messages/private_chat.dart:22` · `home/song_action_wiring.dart:231/340` ·
`home/queue_sheet_controller.dart:144` · `login_sheet.dart:650`(手写 `ModalBottomSheetRoute`, 全仓唯一 "有名字的路由": `RouteSettings(name: loginSheetRouteName)`)

19 处 dialog(`rg -n showDialog lib`): `playlist_dialogs.dart:14/57/79` · `cloud_page.dart:208/237` · `album_preview.dart:157` · `update_dialog.dart:15` ·
`settings_diagnostics_page.dart:193` · `settings_audio_page.dart:365` · `settings_account_page.dart:161` · `search_landing.dart:53` ·
`play_queue_sheet.dart:211` · `mine_view.dart:190` · `song_action_wiring.dart:301` · `queue_sheet_controller.dart:177` · `home_page.dart:486` ·
`cover_art.dart:369` · `comment_thread.dart:577`

### 1.3 返回栈四层(事件只经过前两层里的"栈顶路由")

```
Android framework  →  targetSdk 36 默认走新返回 API(manifest 无 enableOnBackInvokedCallback ⇒ 取默认值)
                   →  Flutter handlePopRoute(Navigator.maybePop) → 返回 false 则 SystemNavigator.pop
  ↓
Flutter Navigator  →  栈顶路由: 若是 PopupRoute(sheet/dialog) → 直接 pop, 根 guard 完全不参与
                      ("返回键一次退一层"就来自这里, 无需任何代码)
  ↓
根路由 PopScope    →  HomeBackGuard(back_policy.dart:45): canPop = action==exitApp;
                      action ∈ {collapseLyrics, resetTab, closeLibrary, exitApp}(back_policy.dart:16-28)
  ↓
二级页 PopScope    →  只有 history_tab.dart:93(日推"某一天"页内二级); 其余 push 的页面没有 PopScope,
                      默认 pop(符合预期)
```

**同一事件被处理两次?** 没有活路径: 二级页压上来时根 guard 不在栈顶, 系统不会问它(`home_page.dart:949-960`)。
**二级页 onPop 被根 guard 抢走?** 没有, 同上。唯一"全局跳跃"是 `popUntil((r) => r.isFirst)` —— 播放条的
"展开歌词/点封面"在 `pageDepth>1` 时用它回首页(`home_page.dart:285/292`), 会连带 pop 掉压在上面的 sheet, 属有意设计。

### 1.4 生命周期与进程级静态钩子

| 钩子 | 注册点 | 解绑 | 单实例语义 |
|---|---|---|---|
| `Playback.setSkipHandlers`(上一首/下一首/播完) | `home_wiring.dart:88` | 传三个 null(:123) | 静态字段覆盖写 |
| `Playback.setActionHandlers`(喜欢/模式) | `:94` | 两个 null(:124) | 同上 |
| `AppSettings.instance.addListener` | `:98` | `:116` | 自己的闭包 |
| `actionsHost.value` | `:99` | `:125` | `ValueNotifier` |
| `playerBarActions.value`(帧后) | `:100-103` | `:126` | 同上 |
| `ArtistNav.onOpenAlbum` | `:104` | `:127` | 静态字段 |
| `UpdateCheckHost.pendingPrompt` | `:106` | `:117` | 自己的闭包 |
| `pageDepth`(导航让位) | `:107`(值由 `NcmRouteObserver` 维护) | `:118` | 自带 `_latest`(:75, :118) |
| `PlaybackBridge.instance.bind` | `home_page.dart:326-330` | `dispose`: `unbind()` | 单例 |
| `WidgetsBinding.addObserver(_desktopClose)` | `home_page.dart:347` | `:353` | 每实例一个 observer |

`dispose` 顺序(`home_page.dart:350-366`): removeObserver → PlaybackBridge.unbind → `_wiring.detach()` → 各 controller.dispose。
**detach 在 controller.dispose 之前**, 所以"原生动作在 detach 与 dispose 之间到达"只会进 `Playback._pendingNativeActions` 排队区
(`playback.dart:146-166`, 上限 8 条), 不会调到已销毁的 State —— 这条安全。

### 1.5 切页钩子

- **唯一机制**: `NcmRouteObserver`(`app_shell.dart:46-97`)只维护两个全局量: `pageDepth`(非弹层路由数)与 `modalRouteOpen`(弹层在场)。
  它**不暴露**"进入/离开某页"事件, 也不给调用方任何"关掉浮层"的能力(纯计数)。
- **唯一的"切 tab 要做的事"清单**: `_onTabSelected`(`home_page.dart:1095-1129`)一行行手写:
  `dismissLoginSheet()`(:1099) → `_queueUI.close()`(:1103) → 收起歌词(:1114) → 回搜索 tab 时按设置清搜索态(:1116-1128)。
- 各 controller 不知道"当前是哪个 tab", 也不知道"有没有别的东西压在上面"。

## 2. 逐问结论(现象 · 触发 · 证据 · 影响 · 修法 · 成本 · 触发条件)

### 2.1 (问 1) 22 处 sheet 有没有统一 dismiss/关闭语义? 谁管"打开前暂停/关闭后恢复"?

**结论: 没有统一入口, 关闭语义分档, 且没有任何一处做"打开前暂停/关闭后恢复"。**

- 拖拽条: 21/22(`showDragHandle: true`); 唯一没有的是 `song_wiki.dart:21-24`(它用 `onClose` 补)。
- 显式关闭键: 只有 5 处 sheet 传 `SheetHeader(onClose:)` —— `comments_sheet.dart:50`、`login_sheet.dart:363`、`private_chat.dart:38`、
  `podcast.dart:97`、`song_wiki.dart:34`; 其余大面板(`song_actions.dart:215`、`play_queue_sheet.dart:250`、`feed_share.dart:446` …)
  **只有拖拽条 + 遮罩 + 返回键**。
- 高度口径三套: 0.6 屏硬编码(`song_actions.dart:203`、`song_action_wiring.dart:237`)、0.75 屏(`comments_sheet.dart:37`、`song_wiki.dart:28`)、
  `isScrollControlled` 交给内容(`similar_sheet.dart:33`、`cover_quality_sheet.dart:23` …)。
- 键盘让位只有 5 处手写 `viewInsets`(`composer.dart:112`、`replies_sheet.dart:73`、`comments_sheet.dart:35`、`login_sheet.dart:352`、`app_shell.dart:170`)。
- **暂停/恢复: 全仓 0 处**。`rg -n "pause|resume"` 于 `song_action_wiring.dart`/`comment_thread.dart`/`song_share.dart`/`feed_share.dart`/
  `update_dialog.dart` 全部无命中。**这一条本身不是缺陷**(音乐 App 开菜单时不该停播; 播放条在 sheet 打开后仍可操作是有意设计,
  见 `queue_sheet_controller.dart:107-108`)。真正的例外是**视频**: 见 U-04。

**影响面**: 新增第 23 个 sheet 时没有任何强制项 —— 拖拽条、关闭键、键盘让位、切页收起全靠作者自觉。
**修法**: `showAppSheet`(§4.1)。**成本 M**。**触发条件**: 下一次新增/大改任一 sheet, 或再出现"某某弹层关不掉/切 tab 还挂着"反馈。

### 2.2 (问 2) 浮层叠栈: 能否同时存在? 返回键一次退一层还是全退?

**返回键: 一次退一层**(Flutter 对 PopupRoute 的默认行为; 本仓没有任何拦截弹层返回键的代码 → 正确)。

**能同时存在(可达路径)**:

| # | 叠栈 | 可达性 | 证据 |
|---|---|---|---|
| a | 队列面板 **压在** 登录弹层上 | ✅ 播放条在 Navigator 之外, 登录弹层开着时队列按钮仍可点 | `app_shell.dart:236`; `queue_sheet_controller.dart:107-108` 自述 |
| b | "清空播放队列?"对话框 压在 队列面板上 | ✅ | `play_queue_sheet.dart:211` |
| c | 更新弹窗 压在任何浮层上 | ✅ 帧后弹, 不检查栈 | `home_page.dart:405-420` → `update_dialog.dart:15` |
| d | 首次展开队列的"左滑提示"对话框 → 再开面板 | ✅ **顺序正确**(先弹框后开面板, 不共存) | `queue_sheet_controller.dart:139-142` |
| e | 歌曲动作面板 → 下一个面板 | ✅ 但**不是同栈共存**: `run()` 先 `Navigator.pop(context)` 再执行回调 | `song_actions.dart:262-263` → `song_action_wiring.dart:231` |

**"打开 A 时 B 还挂在 Navigator 上"的实例**: 只有 (a)(b)(c)。(a) 已被 `dismissLoginSheet` 的
`isCurrent ? pop : removeRoute` 正确处理(`login_sheet.dart:671-682`); **(b) 处理错了 → U-02**; (c) 是 UX 择时问题, 不算缺陷。

### 2.3 (问 3) 切 tab / push 进二级页 / 冷启动时哪些浮层不会自动收起?

**根因**: `MaterialApp.builder` 里 `PlayerBarHost` 把 `Navigator` 和"播放条 + 导航"放进**同一个 Column 的兄弟位置**
(`app_shell.dart:236` `final column = Column(children: [content, ?bar, ?nav]);`, 宽档另走 `:243` 的 `Row`)。
modal 路由的遮罩只覆盖 `Expanded(child: content)` 那一块 ⇒ **遮罩盖不住导航(窄/中档 `NavigationBar` 与宽档左侧 `NavigationRail`)**, 浮层开着时点 tab 完全有效。
这正是 2026-11-17/18 两次用户反馈的成因, 而修法是逐处手写。

**`_onTabSelected` 现在只收 2 类**: 登录弹层(`home_page.dart:1099`)、队列面板(`:1103`)。
从**首页可达**的其余浮层(能一边开着浮层一边点 tab)全部**不会自动收起**:

| 浮层 | 打开入口 | 切 tab 后 |
|---|---|---|
| 歌曲动作面板 `song_actions.dart:159` | 任意列表行尾 "..."(`song_actions.dart:139-146` 走 `AppActions` 宿主) | 挂在旧 tab 上 |
| 收藏到歌单 `song_action_wiring.dart:231` | 上一项的"收藏到歌单" | 同上 |
| 分享 `song_action_wiring.dart:340` | 同上 | 同上 |
| 关注页艺人筛选 `feed_view_body.dart:242` | 关注 tab 的"全部艺人" | 同上(且 tab 切走后筛选面板还在) |
| 更新弹窗 `update_dialog.dart:15` | 帧后自动 | 同上 |
| 封面质量/相似歌曲/歌曲百科 | 只在二级页出现 | 不可达(二级页无导航: `home_page.dart:1624` `pageDepth>1 → null`) |

**push 进二级页**: 导航自己隐藏(`:1624`), 所以"push 时浮层没收"的真实路径只剩播放条
(`onToggleLyrics`/`onOpenDetail` 先 `popUntil(isFirst)`, `:285/292`)。**冷启动恢复**: 冷启动没有浮层;
播放现场由 `PlaybackCoordinator.restoreFromDisk` 恢复(`playback_coordinator.dart:519-535`), 与浮层无关;
唯一交互是更新弹窗可能压着首帧后的 toast。

**修法**: U-01(浮层注册表 + `_onTabSelected` 一处调用)。**成本 M**。**触发条件**: 下一次"切了栏目弹层还在"的反馈, 或做 §4.1 时顺带。

### 2.4 (问 4) dispose 后回调: `_latest` / 帧后投递 是否真的安全?

分四处看, **两处安全、两处有缺口**:

1. `HomeWiring.attach` 的帧后投递: **安全**。有 `if (!_attached) return;`(`home_wiring.dart:100-102`), 注释点明"建完即销毁的实例不要复活"。
2. `HomeWiring._latest`(:75) 单指针语义: **漏一种组合 → U-06**。
   - 正常序(A attach → A detach): 清空全局, 正确。
   - 多实例(A attach → B attach → **B 先** detach): 全局被清空、`_latest=null`, 而 **A 仍存活且 mounted**, 从此通知栏/skip 回调/动作宿主/
     播放条回调全是 null ⇒ "页面活着但所有进程级入口哑掉"。生产是单 HomePage(不触发), 单测也走不到这个序,
     但它是这套设计的**唯一未定义组合**; "因此不需要引用计数"的论证(`home_wiring.dart:31-33`)正好漏了它。
3. `Playback.setSkipHandlers()` + native 调用: **安全**(§1.4 末段: 排队区 + 上限 8 + 原生侧 `PENDING_ACTION_TTL_MS=60s` 双保险, `PlaybackService.kt:720-750`)。
4. `_publishPlayerBar` / `publishBottomBar` 的帧后回调: **没有 mounted 守卫 → U-05**。`home_page.dart:1609-1618` 与
   `app_shell.dart:122-125` 都在 build 里捕获**属于本页面**的 Widget/数据, 帧后无条件写全局 `ValueNotifier`。
   页面若在"投递 → 下一帧"之间被销毁(测试 teardown、将来的多窗口), 旧闭包/旧 `NavigationBar` 会覆盖新实例的投递一帧;
   更糟的是旧 `NavigationBar` 的 `onDestinationSelected` 会调到已 dispose 的 `_queueUI.close()` → `Navigator.of(已卸载 context)`。

**修法**: U-05 加 `if (!mounted) return;`(S); U-06 在 `detach` 里改成"若 `_latest==null` 且自己仍 mounted 则重新 attach"或改用
"存活实例集合 + 取最后一个"(S)。**触发条件**: U-05 —— 任何一次测试/多窗口踩到白帧或 `deactivated widget` 断言;
U-06 —— 只有引入第二个 HomePage 实例(分屏/多窗口/测试框架)时。

### 2.5 (问 5) 返回栈三层一致性: 有没有同一事件处理两次 / 二级页 onPop 被根 guard 抢走?

**结论: 一致, 无双重处理**(理由见 §1.3)。

- 根 guard 的 `canPop` 与 `onBack` 由**同一个纯函数**算出(`home_page.dart:949-953` → `back_policy.dart:16-28`), 不会"拦了却不处理"。
- `exitApp` 分支里的 `SystemNavigator.pop()`(`home_page.dart:978-983`)在 `canPop=true` 时不可达 → **U-09**(死防御)。
- 预测性返回: `canPop=false` 会关掉手势预览动画(Flutter 既定行为)。当前只在"歌词展开/非首 tab/歌单浏览态/日推某一天"发生,
  可见影响是"手势没有收缩预览", 可接受。
- 桌面 `Esc`: **注释漂移 → U-08**(`back_policy.dart:4,29` 声称"Android 返回键/桌面 Esc"), 而 `rg -n "LogicalKeyboardKey|Shortcuts" lib`
  零命中 ⇒ 根页面按 Esc 不退层级; sheet/dialog 的 Esc 关闭来自 Flutter 自身 `DismissIntent` 语义(**待核实**: 本机无桌面会话, 未实测)。

**修法**: U-08 改注释或补一个 `CallbackShortcuts`(S); U-09 删分支或写清"兜底"(S)。**触发条件**: 下次动 `back_policy.dart` 时顺带;
若用户要桌面 Esc 退层级则单独立项。

### 2.6 (问 6) Kotlin 三个 Activity 的返回键与 Flutter 侧是否一致

| Activity | 返回键实现 | 与 Flutter 一致性 | 证据 |
|---|---|---|---|
| `LoginActivity` | `OnBackPressedDispatcher` + `finishCancelled()` | 独立 WebView 页, 与 Flutter 栈无关; 返回=放弃登录(与顶栏关闭同出口) | `LoginActivity.kt:44-46`, `:63` |
| `MainActivity` | **没有任何返回键代码** | 全交 Flutter(`handlePopRoute`/`HomeBackGuard`), 一致 ✅ | `rg -n "onBackPressed" MainActivity.kt` → 无命中 |
| `MvPlayerActivity` | 无 override(默认 `finish`) | 与 Flutter 无交互(Flutter 侧不知道 MV 页存在), 返回即结束; `onPause` 里 `isFinishing → stopPlayback()`, 否则"暂停 + 记位置" | `MvPlayerActivity.kt:105-131`, `:133-136` |

`AndroidManifest.xml` 里**没有** `android:enableOnBackInvokedCallback`(全文 `rg` 无命中) ⇒ targetSdk 36 取默认(新返回 API),
`LoginActivity.kt:40-43` 的注释与此一致。两个没有 override 的 Activity 因此**没有遗留写法风险**。

**不一致点不是返回键, 是"MV 页生命周期对 Dart 不可见"**(→ U-04: 播 MV 前不暂停歌曲, MV 结束也没有回调)。
另: `MainActivity.onDestroy` 会置空 `PlaybackService` 的三个 listener(`MainActivity.kt:579-586`), 与 Dart 侧 `HomeWiring.detach` 是**双保险**
(清的是各自语言的字段), 不冲突。

### 2.7 (问 7) 播放条宿主在 Navigator 之外: 有无可测的退化点?

宿主: `_PlayerBarChrome`(`app_shell.dart:162-264`), 在根 `Overlay` 里(`PlayerBarHost`, `:134-161`)。

| 维度 | 现状 | 结论 |
|---|---|---|
| 键盘让位 | `keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0`(`:170`), 同时隐藏播放条与导航(`:209`) | ✅ 浮层内键盘走同一根 MediaQuery, 判断不打架 |
| 安全区 | 导航栏 bottom inset 夹到 8dp; 无底部导航(含宽档 Rail)时播放条自吃 inset(`:191` `absorbBottomInset: navBar == null || rail != null`) | ✅ 互补; 但"谁吃 inset"由 `navBar == null` / `rail != null` 决定, 与 `pageDepth>1` 强耦合(`home_page.dart:1624`) —— 改导航可见性时要**同时**看这几处(见 U-13) |
| Theme/字号/AppSettings 继承 | chrome 在 `MaterialApp.builder` 之内; 设置变更经 `AnimatedBuilder(AppSettings)` 重建整个 `MaterialApp`(`:267`), 内容经 `didUpdateWidget → _content.value` 刷新, 注释解释了"Overlay.initialEntries 只首次生效" | ✅ 无退化; 代价见 U-10 |
| 重建次数 | 4 层嵌套 `ValueListenableBuilder` + `publishBottomBar` **每次** HomePage 构建都投一个新 `NavigationBar`/`NavigationRail`(`home_page.dart:994`) ⇒ `playerBarSlot` 每次都不相等 | ⚠️ 与注释"内容变了才通知"(`app_shell.dart:120-124`)不符 → **U-10** |
| 播放条数据相等性 | `PlayerBarData.==` 里 `identical(other.current, current)`(`player_bar.dart:56`) | ⚠️ **U-12** |
| [rail] 宽档 Rail 挂载 | Rail 挂在 `Row` 左侧(`app_shell.dart:243-256`), **仍在 Navigator 之外** ⇒ U-01 在宽档同样成立(竖条点击面积更大) | ⚠️ 见 U-13 |
| 页面切换 | 播放条不随路由重建(在 Navigator 外), 只随数据/槽位变化 | ✅ 设计目标达成 |

**可测退化点(建议进 `desktop-smoke` 或 widget 测试)**: ① 打开 sheet 后播放条仍可点(现状, 有意);
② `playerBarSlot` 每次 HomePage rebuild 都通知(可用 `ValueNotifier` 监听计数断言, 修 U-10 前基线=每次都 +1)。

### 2.8 (问 8) 生命周期与音频: 有没有"以为还活着"的 Dart 状态?

**事实**:

- Dart 侧**没有任何生命周期监听**(全仓 `AppLifecycleListener`/`didChangeAppLifecycleState` = 0); 唯一 observer 是桌面关闭分流(`desktop_shell.dart:258-283`)。
- 轮询 `Timer.periodic(500ms)`(`playback_coordinator.dart:134-136`)后台照跑; 歌词 ticker 只在歌词展开时跑。
- 现场落盘 5s 节流(`playback_coordinator.dart:548-560`, 播放态/切歌时 force)。
- Android 服务侧: 正在播放时 `onTaskRemoved` **不** `stopSelf`(`PlaybackService.kt:279-285`); 上划清任务后 MainActivity 销毁 ⇒ Dart isolate 消失,
  通知按钮改走"拉起 App + 意图排队 + 60s TTL + 握手后补执行"(`PlaybackService.kt:741-772`, `playback.dart:146-176`, `MainActivity.kt:531-560`)。
- 桌面托盘隐藏: 窗口 unmap, Dart 进程继续跑(`desktop_shell.dart:180-186` `hideToTray` → `AppExitResponse.cancel`), 轮询/播放状态**没有**断。

**结论: 目前没有"以为还活着"的可证缺陷**。三条支撑: ① Android 最坏情况(Activity 没了)已被原生兜底加固;
② 桌面"隐藏"不销毁 isolate, 状态天然连续; ③ 回前台不需要任何 Dart 动作(播放由原生继续, UI 由 500ms 轮询自然追上)。
**真正的空档是"没有钩子"本身**: 一旦要做"回前台刷新数据/进后台降频/锁屏暂停", 全仓没有落点。
**修法**: 在 `HomeWiring` 旁边加 `AppLifecycleObserver`(与 `DesktopCloseObserver` 同形态, 单实例, attach/detach 成对)。
**成本 S~M**。**触发条件**: 出现"回前台后数据明显过期"或"后台耗电"反馈。

### 2.9 [rail] 在飞车道(宽档 NavigationRail + 内容限宽)的四个耦合点 —— U-13

工作树里未提交的 `lane/ui-adaptive` 改动会影响本文多处结论, 登记为一条 P3(只登记, 不碰别人的在飞改动):

1. **"谁吃底部 inset" 又多一个判断**: `absorbBottomInset: navBar == null || rail != null`(`app_shell.dart:191`), 与 `:209` 的
   `nav == null || keyboardUp || rail != null`、`home_page.dart:1624` 的 `pageDepth > 1 → null` 构成三点耦合。任何一处漏改的表现是
   "播放条贴不到屏幕底边 / 导航与播放条之间冒空白"(2026-11-13 已踩过一次同类)。
2. **U-01 在宽档不变**: Rail 挂在 `Row` 左侧(`app_shell.dart:243-256`), 同样在 Navigator 之外 ⇒ 浮层开着时仍可点导航;
   竖条点击面积更大, "切栏目后弹层还挂着"在桌面宽窗上更容易被撞到。修法不变(浮层注册表)。
3. **浮层宽度语义变化(需人眼确认)**: `ContentWidthLimit` 包的是 `Expanded(child: body)`(即 Navigator), `kContentMaxWidth = 840`
   (`layout.dart:440`) ⇒ 超宽窗口下 modal sheet / dialog **也会被限宽到 840 并居中**。这可能是想要的(浮层与内容对齐),
   也可能是"桌面上面板突然变窄"的观感回归 —— **待核实(需人眼/桌面截图)**。
4. **"浮层在场"有了第二份手写记账**: 新代码的 `modalRouteOpen`(`app_shell.dart:43`, 由 `NcmRouteObserver` 的 `_popups` 计数维护)
   与 `dismissLoginSheet` 的 `_openLoginRoute`、`QueueSheetController._open` 是**三份各自维护的浮层状态**。
   它正好是 §4.1 注册表的雏形, 但**计数器不能关浮层** —— 所以替代不了 U-01/U-02 的修法, 只能当"浮层在场"的判据;
   而且与 U-07 同病: `didReplace` 未处理, 一次 `pushReplacement` 会让它永久停在 true(留白永远压暗)。

**成本 S**(判据收敛 + 注释); **触发条件**: 该车道合并前让作者按上面四点自查一次; 合并后若出现观感问题再单独修。

### 2.10 (问 9) 目标形态建议

#### 4.1 建议 1(核心): `showAppSheet` 单一入口 + 浮层注册表

**形态**(新增 `ui/lib/src/app_sheet.dart`, 约 120 行):

```dart
Future<T?> showAppSheet<T>(BuildContext context, {
  required String title,          // 必填 → 强制有 SheetHeader
  String? subtitle,
  double? heightFactor,           // 归一 0.6 / 0.75 / 自适应三档
  bool keyboardAvoid = false,     // 需要输入时自动垫 viewInsets
  Widget Function(BuildContext) builder,
});
// 内部: 造 ModalBottomSheetRoute(带 RouteSettings(name: 'app-sheet:<seq>')),
//       注册进 AppOverlayStack(吸收 modalRouteOpen 的计数), 返回 Future

abstract final class AppOverlayStack {
  static void dismissSheets();   // 只关自有 sheet(按栈序, 不碰页面)
  static void dismissAll();      // sheet + 自有 dialog
  static ValueListenable<bool> anyOpen;
}
```

- **收益**: ① U-02 消掉(`close()` 不再靠 `maybePop` 猜栈顶, 直接 `removeRoute` 自己那条);
  ② U-01 消掉一半(`_onTabSelected` 从"逐处手写"变成一行 `AppOverlayStack.dismissSheets()`);
  ③ U-03 的关闭语义/高度/键盘三口径一次归一; ④ `modalRouteOpen`、`_openLoginRoute`、`_open` 三份记账并成一份。
- **成本**: **M**(22 个调用点 + 现有 widget 测试回归: `queue_sheet_*`、`login_sheet_*`、`similar_sheet`、`play_queue_sheet` 等)。
- **风险**: 中 —— `play_queue_sheet`/`comments_sheet` 的键盘让位与固定高度必须在入口里参数化到位, 否则"面板被键盘顶飞"会回归;
  `feed_share` 三个面板共用 `_ShareSheetFrame`(`feed_share.dart:415`), 迁移要保住这个内联 frame 的视觉。
- **迁移顺序**(每步独立可发布):
  1. 新增 `app_sheet.dart` + 一个测试, **不改任何调用点**(零风险);
  2. 迁**高风险三点**: 队列面板(`queue_sheet_controller.dart:144`)、登录弹层(`login_sheet.dart:650`)、评论面板(`comments_sheet.dart:28`);
  3. 其余 19 处按"下次触碰该文件时顺带迁", 不专门开批。

#### 4.2 建议 2: 切页钩子留在 `NcmRouteObserver` 一层, 不引 RouteAware

- `NcmRouteObserver`(`app_shell.dart:46-97`)已能提供"有没有全屏页压着"。**扩展而不替换**: 加一个
  `ValueNotifier<String?> currentRouteName`(从 `route.settings.name` 取), 各页**按需读**, 不做全局订阅。
- **收益**: "切 tab 收起 X / 切页刷新 Y"有落点, 且没有 observer 泄漏(引 `RouteAware` 要每页 `subscribe/didPopNext/unsubscribe`, 本仓 0 先例)。
- **成本 S**; **风险 低**; **顺序**: 与建议 1 同批或之后。

#### 4.3 明确不建议改

| 不建议 | 为什么(证据) |
|---|---|
| 引 `go_router`/`auto_route` | `pageDepth`/`modalRouteOpen`、`popUntil(isFirst)` 回首页、`PlayerBarHost` 在 Navigator 之外 三处设计都建立在裸 `Navigator` 上(`app_shell.dart:236`、`home_page.dart:285/292`); 换路由框架是 L 级, 无用户可见收益 |
| 给所有浮层加"打开即暂停" | 音乐 App 开菜单/看评论时停播是退步; 播放条本就"浮层开着也能用"(`queue_sheet_controller.dart:107-108`)。**只对视频**加互斥(U-04) |
| 统一改造 19 个 dialog | 全是短促确认(清空/重命名/二次确认), `barrierDismissible` 与取消/确定语义本就与 sheet 不同; 套 `showAppSheet` 只多一层包装 |
| 全局拦截桌面 Esc 退层级 | 现在 Esc 只影响 PopupRoute(Flutter 语义); 给根页面加 Esc=返回会与"Esc 关浮层"冲突, 桌面用户预期是关浮层。没有需求前不做 |
| 把 `HomeWiring` 改成引用计数 | 单实例是产品事实; 只需补 U-06 那一种组合, 不需要通用机制 |
| 让 `_publishPlayerBar` 改成同步投递 | 同步写会在 build 期 `markNeedsBuild` 祖先 → `publishBottomBar` 的注释已记录该坑; 只补 mounted 守卫(U-05) |

## 3. 排序(收益 / 风险 / 成本)

| # | 改动 | 收益 | 风险 | 成本 | 建议批次 |
|---|---|---|---|---|---|
| 1 | U-05 帧后回调补 mounted 守卫 | 中 | 极低 | S | 随任意 UI 批 |
| 2 | U-01 `AppOverlayStack.dismissSheets()` 接进 `_onTabSelected` | **高**(消掉整类"切 tab 弹层还挂着") | 低(只多关, 不误关页面) | S(先手写注册表)/M(等建议 1) | 与 U-02 同批 |
| 3 | U-02 `close()` 自指关闭 | 中(队列面板 + 确认框组合) | 低 | S(局部) | 同上 |
| 4 | U-04 MV/歌曲互斥 + 返回恢复 | 中高(用户可直接感知) | 中(要 platform 回调) | S~M | **需真机核实后** |
| 5 | U-06 `_latest` 组合兜底 | 低(仅测试/多实例) | 极低 | S | 随 U-05 |
| 6 | 建议 1 `showAppSheet` + 迁 3 个高风险点 | 高 | 中 | M | 独立一批 |
| 7 | U-07/U-08/U-09/U-10/U-12/U-13 | 低(注释漂移/死分支/微重建/判据耦合) | 极低 | S | 触碰即改 |
| 8 | U-11 生命周期钩子 | 目前 0(无可证缺陷) | 低 | S~M | 等真实需求 |

**批次建议**: "返回栈/浮层小批"(#1 + #2 + #3 + #5, 半天, 含 `flutter test` 全量)可发 patch;
建议 1 单独一批(minor)。U-04 必须先真机听一次再排。

## 4. 复现命令附录(全部只读)

```bash
cd ui
# 0) 规模与浮层入口
rg -n "showModalBottomSheet" lib | wc -l ; rg -l "showModalBottomSheet" lib | wc -l
rg -n "showDialog" lib | wc -l ; rg -l "showDialog" lib | wc -l
rg -n "showAppSheet|showAppDialog" lib        # 预期: 无输出
# 1) 返回栈/生命周期钩子
rg -n "PopScope|WillPopScope|BackButtonListener|NavigatorPopHandler|RouteAware|didPopNext" lib test
rg -n "AppLifecycleListener|didChangeAppLifecycleState" lib   # 预期: 无输出
rg -n "addObserver" lib
rg -n "LogicalKeyboardKey|Shortcuts" lib      # 预期: 无输出(→ U-08)
rg -n "class NcmRouteObserver|modalRouteOpen|pageDepth" lib/src/app_shell.dart
# 2) 切 tab 的浮层收起点
rg -n "dismissLoginSheet|_queueUI.close" lib/src/home/home_page.dart
rg -n "void close\(\)|maybePop" lib/src/home/queue_sheet_controller.dart
# 3) 根布局(为什么遮罩盖不住导航)
rg -n "Expanded\(|return Column\(|return Row\(" lib/src/app_shell.dart
# 4) MV 与歌曲互斥
rg -n "_startPlayback" -A 25 lib/src/mv_page.dart
rg -n "AudioFocus|requestAudioFocus" android/app/src/main/kotlin   # 预期: 无输出
# 5) 帧后投递是否有守卫
rg -n "addPostFrameCallback" lib/src/home/home_page.dart lib/src/app_shell.dart lib/src/home/home_wiring.dart
# 6) Kotlin 返回键现状
rg -n "onBackPressed|OnBackPressedCallback" android/app/src/main/kotlin
rg -n "enableOnBackInvokedCallback" android/app/src/main/AndroidManifest.xml   # 预期: 无输出(取默认)
```

## 5. 明确不做 / 边界

- 本文件**只登记不排期**(口径同 `docs/remaining-batches.md` §13); 不改任何产品代码/测试, 不写 `docs/PROGRESS.md`。
- 未跑的验证: `flutter test`(含 `queue_sheet_controller_test.dart` 291 行 / `ui_batch_a_back_nav_test.dart` 220 行的现状断言)、
  真机听感(U-04)、桌面 Esc 实测(U-08)、桌面托盘隐藏后的实际重建次数、宽屏浮层限宽观感(U-13-3) —— 均标"待核实", 未计入结论。
- 不重提: `main.dart` 拆壳(已完成 S0–S8)、引完整路由框架、`kSongRowPadding` 二分(已裁决不做)。
