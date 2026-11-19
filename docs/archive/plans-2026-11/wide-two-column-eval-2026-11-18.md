# 横屏/宽屏双列布局评估(N5, 2026-11-18 · 只读)

需求原文:「横屏设备排版把页面做成左右两个纵列, 需要派子代理评估合适的两列布局。」

本文件**只评估, 不改产品代码**。

> **行号口径**: 下列 `文件:行` 抓取于 2026-11-18 15:11 的工作树快照。写这份文件时另有车道在改
> `ui/lib/src/layout.dart`(播放条专辑名 `kPlayerBarAlbumMinWidth`)与 `home_page.dart`(睡眠定时等),
> 行号会继续漂移 ⇒ **以每处附带的符号名为准**, 行号只是找位置的捷径。

## 0 结论先行(数字)

| 项 | 数值/结论 |
|---|---|
| 宽档页面可用宽度 | **840**(`layout.dart:447` `kContentMaxWidth`; 由壳层唯一挂载点 `app_shell.dart:258-265` 施加, 页面改不了) |
| 所以双列只能是 | 840 内切分: 左 **300** / 间距 **12** / 右 **528**(≈5:8)。想更宽必须先动壳层(方案 C) |
| 桌面默认窗口 | 1280x720(`ui/linux/runner/my_application.cc:389`, `ui/windows/runner/main.cpp:31`)⇒ 单列时左右各白留 **220dp** |
| 值得双列的页面 | **2 个详情页**(歌单 / 播客) + 1 个可选项(我的); 搜索 / 推荐 / 动态 / 设置**不建议** |
| 28 处 `Navigator.push` 要改几处 | **0 处**(方案 A); **1~2 处**(方案 B 最小切片) |
| 横屏手机(780x360) | **不加双列**: 高度不够(可视高 ~210), 两条独立滚动各只看 3 行 ⇒ 判据必须同时看宽**和**高 |
| 推荐 | **方案 A(页内双列), 第一刀只做歌单详情**; 方案 B 只在用户明确要「点列表右边换详情、列表不消失」时做; 方案 C 不做首批 |
| 是否需要新全局槽位 | A **不需要** / B 需要 `detailPaneSlot`(仿 `playerBarSlot`) / C 需要 `contentWidthRequest` |

一句话: 用户说的「左右两个纵列」用**页内双列**就能满足, 且完全绕开返回键、`pageDepth`、浮层登记表三个雷区;
「列表不消失的主从分栏」是另一件事, 成本 2~3 倍, 且必须新增返回键语义层级与第二套行高亮。

---

## 1 现状地图

### 1.1 页面形态(哪类页面值得双列)

| 页面 | 形态 | 滚动容器(文件:行) | 状态归属 |
|---|---|---|---|
| 搜索 tab | 三段式分派: 落地页 / 结果 / 浏览态 | `home/home_page.dart:1349` `_buildSearchTab` | `HomePage` + `home/search_controller.dart` + `home/account_actions.dart` |
| 搜索结果 | **列表→详情型**(列表端) | 分类条 + 每次只渲染一个分类 `ListView`(`search_results.dart:210`) / `CoverGrid`(`search_results.dart:325` `_grid`) | `_SearchResultsViewState._selected`(`search_results.dart:104`) |
| 推荐 | **单流式**(5 模块纵向堆) | 单 `ListView`(`recommend_view.dart:102`) | 各 section 自己持 future |
| 关注(动态) | 单流式 | `feed_view.dart`(7 行再导出)→ `PagedListView` | `_PagedListViewState`(`paged_list_view.dart:111`) |
| 我的 | 单流式(模块堆叠) | 单 `ListView(padding: kPageInsets)`(`mine_view.dart:267`) | `_MineViewState`(profile / playlists / radios / albums 各自 future) |
| 设置 | 单流式(list of groups) | `settings_view.dart` | `AppSettings` 单例 |
| **歌单详情** | **详情端** | 单 `CustomScrollView`(`detail/playlist_detail_page.dart:486-511`), controller = `_scroll`(`:83`) | `_PlaylistDetailPageState`(`:82`): `_detailFuture` / `_songs` / `_liked` / `_filter` |
| **播客详情** | 同构详情端 | 单 `CustomScrollView`(`detail/podcast_detail_page.dart:148`) | `_PodcastDetailPageState` |
| 歌单广场 | **列表→详情型**(列表端) | `PagedListView` 网格(`playlist_square_page.dart:132`), 宽度感知已就绪(`paged_list_view.dart:254`) | `PagedListView` + 页内 `_cat/_highQuality` |
| 艺人 / 他人主页 | 列表→详情型(多层) | `NestedScrollView` + `SliverAppBar` + `TabBarView`(`profile_scaffold.dart` 文件头) | `ProfileTabSpec` |

### 1.2 决定方案边界的五条结构事实

1. **内容上限由壳层单点施加**(840, `app_shell.dart:258-265` 的 `Expanded(ContentWidthLimit(...))`):
   页面拿到的就是 840,**没有反向通道**。任何「两栏各 500+」都要先改壳层(方案 C)。
2. **push 出去的全屏页在宽档没有 Rail**:`home_page.dart:1669` `if (pageDepth.value > 1) return null;`
   ⇒ 详情页不是「右侧列」, 而是「整窗居中 840」, 1280 下左右各 220 留白。这条与双列**正交**,
   单独一行能改(见 §4「不建议做的部分」第 2 条)。
3. **浮层登记表只挂在根 Navigator**:`app_shell.dart:327` `navigatorObservers: [NcmRouteObserver()]`,
   `NcmRouteObserver`(`:47`)是 `dismissAllPopups`(`:119`)/`modalRouteOpen`(`:44`)的唯一数据源。
   ⇒ 任何「嵌套 Navigator 承载详情」的做法都会让详情里的 sheet/确认框**漏登记**(U-01/U-02 复发)。
4. **返回键策略只属于 HomePage**:`back_policy.dart:14` `enum HomeBackAction` + `:16` `resolveHomeBackAction`
   + `home_page.dart:983/1001`(`_handleBack`)。被 push 的页面返回交给 Navigator(Scaffold 自动出箭头)。
   ⇒ 新增「详情层」必然要给这个枚举加一级。
5. **仓库里唯一的「主视图替换」先例**:`libraryOpen`(歌单浏览态, `account_actions.dart:153/176`)
   不 push, 直接顶替搜索 tab(`home_page.dart:1350` 附近的分派)。它证明「同一 tab 内换主视图」可做,
   但它**没有左列表 + 右详情**, 也没有选中态, 不能直接复用。

---

## 2 候选方案

三个候选的分歧只有两点:双列切在**哪一层**(页面内 vs 壳层), 以及 **840 让不让**。

### 方案 A · 页内双列(页面自己把内容切左右两栏)

**几何**: 可用宽 ≥ 900 **且** 高 ≥ 560 时, 页面 body 换成
`Row([左栏(SizedBox(width: 300), 独立滚动), 间距 12, 右栏(Expanded, 独立滚动)])` —— 840 下右栏 = 528。
AppBar 保持整宽(Scaffold 不动), 双列只在 `body` 内发生。

- **用在哪**: 歌单详情(左=头部卡/编辑提示/无版权提示, 右=筛选条 + 曲目 + 评论)、播客详情(同构)、我的(打包式, §3 S3)。
- **不该用**: 搜索(结果已经「一次一个分类」, 再拆两栏等于把同一类劈成两半)、推荐 / 动态(单流式模块, 拆开每栏 ~400 只放得下 2.5 张封面)。
- **列表选中态与详情的关系**: **没有这层关系** —— 列表和详情在同一个页面里, 不存在「选中哪一行」。
  播放高亮仍走全局 `nowPlayingSongId`, **不新增第二套高亮词汇**。
- **窄/中档退化**: `twoColumnFor(size) == false` ⇒ 走原 build 分支, **一行不改、零几何变化**
  (与 `ContentWidthLimit`(`layout.dart:488`)「<= 840 时完全不插入 widget」同一哲学)。
- **与既有件的交互**:
  - `ContentWidthLimit`: 只在外层限宽, 双列在其**内部**发生 ⇒ 完全相容, 不需要改壳层;
  - `NavigationRail` / `pageDepth`: **不涉及**(没有新路由, 层数不变);
  - 返回键: **不涉及** ⇒ 需求里担心的「返回键只退详情不退页」在本方案**结构上不可能发生**;
  - 浮层: 不涉及(没有嵌套 Navigator)。
- **新全局槽位**: **不需要**。
- **实现要点(歌单详情)**: `_scroll`(`:83`)与 `_listKey`(`:84`)语义是「曲目列表」,
  双列时**继续挂右栏** ⇒ `_locateCurrent`(`:411-435` 的 `_scroll.hasClients` / `_listKey.currentContext` /
  `maxScrollExtent`)不用改语义。左栏另起 controller 或不设 controller。
  两个分支互斥, 同一 controller 不会同时 attach 两个 ScrollView。

### 方案 B · 壳层主从分栏(列表留在左, 详情在右, 不 push)

**几何**: 壳层 `Row([Rail 80, master Expanded, 间距 12, detail 460])`; 1280 ⇒ master ≈ 728、detail 460。
master 仍受 840 逻辑约束, 但要改成「给 detail 让位后的剩余宽」⇒ `ContentWidthLimit` 从定值 840 变成两档。

- **用在哪**: 只有真「列表→详情」型: 搜索结果里的歌单/专辑、歌单广场、我的收藏、艺人页 tab。
- **不该用**: 推荐 / 动态 / 设置(没有「详情」可放)。
- **列表选中态与详情的关系**: **必须有** —— 右栏换详情时左栏要有一行明显的选中高亮。
  而现有唯一的「行态」是播放中高亮(全局 `nowPlayingSongId`)。⇒ 要么给 `SongRow`(`song_tile.dart`, 857 行)加
  `selected` 参数(第二套高亮词汇, 用户难分辨「选中」与「在播」), 要么加外框 —— 两种都要动契约件 + 回归网。
  **这是本方案最容易被低估的成本。**
- **窄/中档退化**: 保持现有 push(调用点统一走 `openDetail(context, builder)`, 由它分档)。
- **与既有件的交互(三个洞)**:
  1. **详情页不可内嵌**: `_PlaylistDetailPage` 是私有类且自带 `Scaffold + AppBar + 分享/管理 actions`
     (`detail/playlist_detail_page.dart:444-485`)。内嵌必须加 `embedded` 模式(去 AppBar / 去返回箭头),
     否则右栏里会出一个「返回箭头退整页」的错语义。
  2. **不能用嵌套 Navigator 绕开 1**: 嵌套 Navigator 能让现有页面零改动复用, 但 `NcmRouteObserver`
     只挂根(`app_shell.dart:327`)⇒ `dismissAllPopups`(`:119`)/`modalRouteOpen`(`:44`)失效(U-01/U-02 复发);
     若给嵌套 Navigator 也挂 observer, `pageDepth`(`:36`/`NcmRouteObserver._up` `:65`)会被双计。
  3. **返回键要新增一级**: `HomeBackAction`(`back_policy.dart:14`)加 `closeDetailPane`,
     `resolveHomeBackAction`(`:16-24`)插在 `resetTab` 之前, `_handleBack`(`home_page.dart:1001`)加分支,
     `ui_batch_a_back_nav_test` 跟着补。且必须明确**两条不同语义**: 宽档 pane 内返回 = 清空 pane(不 pop 页面);
     窄档 = pop 页面。这正是需求原文担心的「返回键只退详情不退页」的**镜像问题** ——
     它不是 bug, 而是必须写进测试的**设计选择**。
- **新全局槽位**: **需要** `detailPaneSlot`(`ValueNotifier<Widget?>`, 仿 `playerBarSlot` `app_shell.dart:137`)
  + 统一入口 `openDetail(context, builder)`。
- **附带收益**: `pageDepth` 保持 1 ⇒ Rail 不消失、两侧 220 留白消失(窗口利用率最高)。

### 方案 C · 页内双列 + 放宽限宽(840 → 1120)

即方案 A 的放大版: 双列页在 1120 下切 左 360 / 12 / 右 748。

- 需要新全局槽位 `contentWidthRequest`(`ValueNotifier<double?>`), 由双列页 `initState`/`dispose` 写入,
  壳层 `ContentWidthLimit`(`layout.dart:488-527`)读它。
- **麻烦点**: 路由可能叠两层(详情之上再 push 艺人页), 「谁有权改宽」需要栈或 token;
  壳层限宽一旦从「单点定值」变成「可协商」, `content_width_limit_test.dart` 的 4 例与 `nav_rail_shell_test`
  的坐标断言(840 / left 220)都要重写。
- **收益有限**: 840 的论据是「正文可读宽度」(`layout.dart:445`), 而双列页每栏本来只有 300/528;
  放宽只解决「整窗两侧白留 220」的观感, 不解决内容本身。
- **结论**: 不做首批; 等 A 落地后用户对留白有明确抱怨再做, 且优先考虑「A + 详情页保留 Rail」这个更便宜的组合。

---

## 3 推荐方案 + 迁移顺序

**推荐: 方案 A**。理由按权重:

1. **零导航语义风险**: 不新增路由 ⇒ `pageDepth` / Rail 让位 / `dismissAllPopups` / `back_policy` **全不动**,
   需求点名担心的返回键问题在结构上不可能出现。
2. **可单页验证**: 第一刀只碰 `detail/playlist_detail_page.dart:442-511`(build) + `layout.dart` 一个纯函数。
   不动壳层 ⇒ 其余 150 个页面零风险。
3. **可测**: 两栏矩形能 `tester.getRect` 精确断言, 不靠肉眼。
4. 反例对照: 方案 B 的三个洞每一个都是**跨文件**改动, 其中第 2 个会让刚修好的 U-01/U-02 有回归风险。

### S0 断点纯函数(S · 不改 UI)

- `ui/lib/src/layout.dart` 新增(放在「布局档位」小节, 即 `enum LayoutTier`(`:422`)之后):
  - `kTwoColumnMinWidth = 900`(沿用宽档下界, **不造第四个宽度阈值**);
  - `kTwoColumnMinHeight = 560`(1280x720 桌面/平板横屏够; 手机横屏 780x360 **不够**);
  - `bool twoColumnFor(Size size)` —— 无限 ⇒ true, NaN ⇒ false(与 `layoutTierFor`(`:460`)口径一致);
  - `kTwoColumnLeftWidth = 300`、`kTwoColumnGap = 12`(12 已在 `check-tokens` 的 spacing 集合内, 但仍须具名常量)。
  - 判据**只用 `LayoutBuilder` 的实测宽**(与 `kPlayerBarAlbumMinWidth`(`:160`)刚立的先例一致),
    不用 `MediaQuery.sizeOf`:壳层限宽后两者在宽档会分叉。
- 验收: `ui/test/two_column_breakpoints_test.dart` 8 例纯单测——
  899x800 false / 900x559 false / 900x560 true / 780x360 false(横屏手机) / 1280x720 true /
  2560x1440 true / `Size(infinity, 800)` true / `Size(double.nan, 800)` false。
- 门: `dart analyze` 0 issue · `tools/check-tokens.sh --strict` OK。

### S1 歌单详情双列(M · 第一刀, 也是唯一必须做的一刀)

- `detail/playlist_detail_page.dart:486-511`:body 从「一个 `CustomScrollView`」变成
  `LayoutBuilder` + `twoColumnFor(constraints.biggest)` 二分:
  - false ⇒ **原样返回现有 `CustomScrollView`**(几何零变化);
  - true ⇒ `Row([SizedBox(width: kTwoColumnLeftWidth, child: 左 ListView(header card / editing banner / hidden note)), SizedBox(width: kTwoColumnGap), Expanded(右 CustomScrollView(toolbar + songs + comments))])`。
- `_scroll`(`:83`)**继续挂右栏**; `_locateCurrent`(`:411-435`)语义不变(「滚到正在播放的曲目」)。
- 验收(`ui/test/playlist_detail_two_column_test.dart`, 新):
  1. 1280x720:两栏都在; 左栏 `rect.width == kTwoColumnLeftWidth`、`rect.left == (1280-840)/2`;
     右栏 `rect.left - 左栏.right == kTwoColumnGap`; 右栏右边 == 内容区右边;
  2. 900x800:同上(最小可用宽);
  3. 899x800 与 360x800:只有**一个** `CustomScrollView`, 矩形 == viewport 内容区(证明退化分支不动几何);
  4. 780x360(横屏手机):单栏(证明**高度**判据生效);
  5. 300dp + 1.25 字号:仍单栏, `tester.takeException() == null`(不竖溢);
  6. AppBar 仍整宽(`rect.width == 内容区宽`), 不跟着左栏缩。
- golden:新增 **1 张** `playlist_detail_1280x720.png`(12 帧, 沿用 `_TolerantGoldenFileComparator`)。
  **只对该用例 `--update-goldens`(`--plain-name` 过滤), 不要整文件重出 18 张**。
  首次引入宽档基准要先认这条账: 以后动 `kContentMaxWidth` / `kTwoColumnLeftWidth` 都要重出这一张。
- 顺带 eyeball(不算改动):1.625 字号下左栏 header card 的 `Row`(封面 + 文本列)在 300 宽内不竖溢。

### S2 播客详情复用骨架(S)

- 抽 `TwoColumnBody`(三参数: 左栏 builder / 右栏 builder / 单栏 builder)到 `layout.dart` 或新
  `ui/lib/src/wide_two_column.dart`;**只给详情页用**, 不做「万能双列容器」。
- `detail/podcast_detail_page.dart:148` 换成同一骨架; 复用 S1 的测试模板。
- 验收:同 S1 前 4 条(golden 可选 1 张, 不加也可 —— 两页同构)。

### S3 我的页打包式双列(M · 可选, 先量再做)

- 与 S1 不同: 左右两栏**不独立滚动**(单 `ListView` 里的 `Row` 两列), 因为左栏(资料头 + 自页入口 + 消息入口)
  比右栏(歌单/播客/专辑横滑条 + VIP/勋章)短得多。
- **前置测量**: 测试里 `getRect` 两列内容高, 高度差 > 40% 就**不做**(空一大截比单列更丑), 判据写进测试。
- 验收:1280x720 两列矩形 + 高度差断言; 360x800 单列; 现有 `goldens/mine_360x800.png` 不重出。

### S4 方案 B 单流程(L · 仅当用户明确要「列表不消失」)

- 最小切片:**歌单广场 → 歌单详情**(或「搜索结果 → 歌单详情」)一条。
- 前置: `detailPaneSlot` + `openDetail` 入口 + `_PlaylistDetailPage` 的 `embedded` 模式 +
  `HomeBackAction.closeDetailPane` + 选中高亮参数 + `modalRouteOpen` 让位复核。
- 验收:1280x720 点左栏歌单 ⇒ 左栏仍在、右栏出详情、该行有选中态; 按 Esc/返回 ⇒ **只**清右栏;
  再按 ⇒ 退出浏览态/换 tab(`back_policy` 新层级两条语义各一例); 窄档同操作仍走 push(pageDepth +1);
  右栏详情里弹 sheet 仍被登记(`tab_switch_popups_test` 扩 1 例)。

---

## 4 成本与风险

| 步骤 | 规模 | 触碰文件 | 主要风险 |
|---|---|---|---|
| S0 | **S** | `layout.dart` + 1 新测试 | 几乎没有; 唯一要守的是别造第四个宽度阈值 |
| S1 | **M** | `detail/playlist_detail_page.dart` + 1 新测试 + 1 golden | 两条独立滚动的手感; 左栏短时空白; 首次引入宽档基准 |
| S2 | **S** | `podcast_detail_page.dart` + 抽容器 | 抽容器时容易顺手做成「万能容器」(违反 UI 规则层「往容器塞内容, 不新写骨架」的另一面) |
| S3 | **M** | `mine_view.dart` | 左右高度失衡(先量后做, 差 > 40% 就不做) |
| S4 | **L** | 壳层 + `back_policy` + 详情页 embedded + `song_tile` + 3~4 份测试 | observer 漏登记 / pageDepth 双计 / 两套高亮词汇 |

### 明确不建议做的部分

1. **28 处 `Navigator.push` 全改成分栏** —— 其中 20 处是设置子页 / 消息 / 勋章墙 / MV / VIP 等
   **没有列表语境**的页, 改成 pane 只会得到「右栏孤零零一张卡 + 左栏空着」。判定:**不做**。
2. **把「push 时保留 Rail」顺手并进双列批** —— 它是 1 行(`home_page.dart:1669`), 与双列**正交**,
   但会动 `nav_rail_shell_test` 与 `tab_switch_popups_test`(后者显式锁「浮层不算一层」)的既有断言。
   要单独立一条小批, 别混进 S1 的验收口径。
3. **顶栏通栏** —— 需要把限宽从壳层下移到每个页面的 `Scaffold.body`, 成本 = 150+ 次改动。判定:不做。
4. **嵌套 Navigator 承载右栏详情** —— 见 §2 方案 B 洞 2, 直接让 U-01/U-02 有回归风险。判定:不做。
5. **搜索结果的分类条改成并列两栏** —— 分类条已是「单横排 + 横向拖拽」的裁决终态(`category_bar.dart`,
   2026-11-14 四轮试错), 再动它就是推翻已定裁决。判定:不做。

---

## 5 明确不做的候选(含理由)

| 候选 | 为什么不做 |
|---|---|
| **靠网格列数实现「双列」**(宽档把 `AppSettings.gridColumns` 临时 ×2) | 列数已经是**用户设置**(2-4, `layout.dart:333` `CoverGrid`), agent 按屏宽偷偷翻倍就是抢用户口径; 且只对网格页有效, 对密集列表(详情页)无效 |
| **竖屏平板也双列** | 需求是横屏; 竖屏 800x1280 时左 300 + 右 500 会把单曲行挤回 300 宽档手感, 且用户没提 |
| **横屏手机(780x360)双列** | 高 360 减 AppBar 56 减播放条 ~90 ⇒ 每栏可视高 ~210, 两条独立滚动各看 3 行。`kTwoColumnMinHeight` 就是为它设的 |
| **播放条改右侧竖向面板**(与双列捆绑) | `ui-adaptive-layout-2026-11-18.md` §4.1 已评估: 要新增竖向排版 + 触碰 `player_bar.dart`(现 512 行, 已有窄/宽两套横向口径) + 3 份几何测试。与「页面双列」无因果关系 |
| **一次性给所有列表页加「选中行」高亮** | 选中态只对方案 B 有意义; 方案 A 下没有列表-详情关系, 加了就是**两套高亮词汇**(播放中 / 选中)并存 |
| **为双列改 `layoutTierFor` 签名**(加 height 参数) | 它有 15 例断点单测(`layout_breakpoints_test.dart`)与 `nav_rail_shell_test` / `content_width_limit_test` 的坐标断言锁着。双列判据**另起** `twoColumnFor(Size)`, 让「导航档位」与「双列」两个决策解耦 |

---

## 6 复核清单(留给实施者, 全是本次只读核查发现的具体坑)

1. `_scroll` / `_listKey`(`playlist_detail_page.dart:83-84`)只能挂右栏; `_locateCurrent`(`:411-435`)
   的 `_scroll.hasClients` 已能兜住「右栏未挂载」, 不要新增可见性判断。
2. 双列分支与单列分支**互斥**: 同一 `ScrollController` 同时 attach 两个 `ScrollView` 会抛
   `ScrollController attached to multiple scroll views`。
3. 左栏**不要**用 `kPageInsets`(`layout.dart:32` —— 页面级 padding, 会给 300 宽再吃 24 + 上下),
   只用 `kPagePadding`(`:29`)单侧。
4. 间距 12 已在 token 集合内, 但仍须具名常量: `tools/check-tokens.sh` 的 `gap` 规则管 **`<= 32` 的 SizedBox**。
5. 行高不受双列影响(`rowExtentFor` 只吃 textScaler, `layout.dart:187`), 别在双列里重算 `itemExtent`。
6. golden 只在 `ui/` 下跑(`golden_pages_test.dart` 文件头); 宽档基准同样依赖 CJK 字体探测。
   本机与 CI 的字体差异由 `precisionTolerance 0.002` 吸收, **别为了消假红重出窄档 18 张**。
