# 横屏 / 宽屏响应式布局(lane/ui-adaptive, 2026-11-18)

一份 Flutter UI 跑 Android / Linux / Windows, 但布局口径一直是**手机竖屏预算**: 300~412dp。
本车道把「宽屏怎么排」从「每个页面自己想办法」变成**壳层布局决策**, 分四阶段落地,
P1~P3 已实施, P4 只写方案。

---

## 1. 调研现状地图(动手前实测)

| 维度 | 现状(2026-11-18 核实) |
|---|---|
| 断点/档位 | **没有** NavigationRail / AdaptiveScaffold / Breakpoints 类; 唯一宽度阈值是 `layout.dart` 的 `kPlayerBarRoomyWidth = 600`(只决定播放条是否用宽屏留白) |
| 内容区限宽 | **没有**。全仓没有把页面内容包进 `ConstrainedBox(maxWidth: …)` 的地方 ⇒ 1280 宽窗口下页面内容左右铺到边、行被拉成两屏长 |
| 导航 | 底部 `NavigationBar`(5 个 tab: 搜索/推荐/关注/我的/设置), 由 `HomePage._buildBottomBar()` 生成后经 `playerBarSlot` 投递给壳层 `PlayerBarHost`, 挂在**根 Overlay / Navigator 之外**, 位置在 Column 底部 |
| 二级页 | `Navigator.of(context).push` **28 处**, 全部全屏 push; 无分栏 / 无内嵌 detail pane |
| 播放条 | `MiniPlayerBar`(host 在 `_PlayerBarChrome` 的 Column 里, 与导航栏并列贴底); 内部按 `MediaQuery` 宽度 >= 600 切两套横向留白(手机预算 / 宽屏预算) |
| 页面数 | 152 个 dart 页面/组件文件(`ui/lib/src/**`), 改一个页面都等于 152 次「同一件事重做」 |
| golden | 18 张(9 页 × {360x800@1.0, 300x640@1.25}), **全在窄视口** |

结论: 影响面最小、覆盖全部页面的挂载点只有一个 —— `app_shell.dart` 的
`_PlayerBarChrome`(Navigator = `body` 就在它里面)。页面自己一行都不用改。

---

## 2. 三档设计

### 2.1 档位与阈值(唯一权威: `ui/lib/src/layout.dart`)

| 档位 | 条件 | 导航位置 | 内容 |
|---|---|---|---|
| `LayoutTier.compact` | 可用宽 < `kCompactMaxWidth`(600) | 底部 `NavigationBar` | 铺满 |
| `LayoutTier.medium` | 600 ≤ 宽 < `kWideMinWidth`(900) | 底部 `NavigationBar` | ≤ `kContentMaxWidth`(840) 居中 |
| `LayoutTier.wide` | 宽 ≥ 900 | 左侧 `NavigationRail`(`kRailWidth` = 80) | ≤ 840 居中 |

判据只有**实际可用宽度**, 不看 device type / platform / 方向:
`layoutTierFor(double width)`; `infinity` ⇒ wide(无限宽绝不落窄档), `NaN` ⇒ compact(保守)。

### 2.2 壳层职责边界

- **壳层**决定「导航在哪、内容多宽」: 唯一实现点在 `_PlayerBarChrome`。
- **页面**只返回内容 widget: 拿到的是被壳层收窄后的可用宽(`LayoutBuilder` 的
  `constraints.maxWidth`), 页面内部一行没改。
- **导航语义**由 `HomePage` 决定(它有 `_tab` 状态), 壳层只负责「放到哪」。
  两者用 `Widget` 类型约定: 投递 `NavigationRail` ⇒ 壳层放左侧; 投递 `NavigationBar`
  ⇒ 壳层放底部(既有行为不变)。

---

## 3. 各阶段改动(文件 + 行)

### P1 断点常量 + 纯函数(已完成)

- `ui/lib/src/layout.dart:399-460` 新增「布局档位」小节:
  `enum LayoutTier {compact, medium, wide}` / `kCompactMaxWidth = 600` /
  `kWideMinWidth = 900` / `kContentMaxWidth = 840` / `kRailWidth = 80` /
  `LayoutTier layoutTierFor(double width)`。**不动任何页面。**
- `ui/test/layout_breakpoints_test.dart`(新, 15 例): 599/600、899/900、0、`double.infinity`、
  `double.nan` + 9 个真实参考宽(300/360/412/540/720/840/1000/1280/2560) + 常量关系。

### P2 内容区统一限宽(已完成)

- `ui/lib/src/layout.dart:462-494` 新增 `ContentWidthLimit`(StatelessWidget):
  `LayoutBuilder` 取实际可用宽, `<= kContentMaxWidth` ⇒ **原样返回 child(不插入任何
  widget, 窄屏几何零变化)**; 否则 `ColoredBox(scaffoldBackgroundColor) + Center +
  ConstrainedBox(maxWidth: 840)`。两侧空白用 `ThemeData.scaffoldBackgroundColor`,
  与页面 Scaffold 底色同源, 换主题 / OLED 自动跟随。
- `ui/lib/src/app_shell.dart:196-198`: `Expanded(child: ContentWidthLimit(child: body))`
  —— 只包 Navigator(body), 播放条与导航栏仍通栏。
- `ui/test/content_width_limit_test.dart`(新, 4 例): 400(宽 400 / left 0)、840(正好等于限宽,
  仍 left 0)、1280(宽 840 / left 220 / 高不变)、留白底色 == Scaffold 底色。

### P3 宽档左侧 NavigationRail(已完成)

- `ui/lib/src/home/home_page.dart:1623-1673`: `_buildBottomBar()` → `_buildBottomBar(BuildContext)`;
  `layoutTierFor(MediaQuery.sizeOf(context).width) == wide` 时返回 `NavigationRail`
  (`labelType: NavigationRailLabelType.all` ↔ 原来 `alwaysShow`; 同一 `_tab` /
  同一 `_onTabSelected`; `pageDepth > 1` 让位判断仍在最前面, 一一对应)。
  `minWidth: kRailWidth`, `scrollable: true`(矮窗口不竖溢)。
- `ui/lib/src/app_shell.dart:150-217`:
  - 判据 `navBar is NavigationRail` ⇒ `rail` 分支; 底部 `NavigationBar` 路径(含
    MediaQuery inset 夹取 top=0 / bottom≤8)一字未动;
  - 布局 `Row(crossAxisAlignment: stretch, [SafeArea(SizedBox(kRailWidth, rail)), Expanded(Column([内容, 播放条]))])`;
    `stretch` 是必须的(NavigationRail 内部有 `Flexible`, 松高度会报 unbounded);
    Rail 自己只处理左右安全区, 顶部/底部由壳层 `SafeArea` 补;
  - 播放条 `absorbBottomInset: navBar == null || rail != null` —— 宽档下没人替它吃
    手势区, 不改的话播放条贴不到底(这是宽档唯一的**行为修正点**)。
- `ui/test/support/nav_chrome.dart`(新): `navChromeFinder` / `navSelectedIndex()`,
  供「断言导航里有某个 tab」的旧测试档位中立地复用。
- `ui/test/nav_rail_shell_test.dart`(新, 5 例): 1000x900 出 Rail 且没有 NavigationBar、
  Rail left=0 / width=80、内容 840 居中于右列(80+40=120); 840x800 与 400x800 只有
  NavigationBar 且内容铺满; 点 Rail 项切 tab(选中态 1→3→0); 1000x420 矮窗口不竖溢。
- 旧测试档位中立化(行为断言不变, 只换查找器):
  `ui/test/ui_batch_a_back_nav_test.dart`(5 处 `widget<NavigationBar>` → `navSelectedIndex(tester)`)、
  `ui/test/top_bar_no_duplicate_test.dart`(2 处 descendant of NavigationBar → `navChromeFinder`)、
  `ui/test/login_sheet_test.dart`(1 处)。这三份的视口仍是 1200 宽 ⇒ 现在实际覆盖的是**宽档 Rail** 路径;
  窄/中档的 NavigationBar 路径由 `nav_rail_shell_test` 与 `bottom_chrome_padding_test` 覆盖。

---

## 4. 未实施项与触发条件(P4 方案)

### 4.1 播放条按位置适配(未实施)

现状: 宽档下播放条仍贴在**右列底部通栏**(宽 = 窗口 - 80), 内容区只有 840 ⇒ 播放条比内容宽,
控件被甩到右下角(与 `kPlayerBarRoomyWidth` 修补前的症状同源, 只是尺度更小)。

- 方案 A(低成本, 推荐先做): 宽档时给播放条也套 `ContentWidthLimit`, 与内容区同宽居中 ——
  纯壳层一处改动(把 `?bar` 挪进 `ContentWidthLimit` 的子列), 预计 10 行, 无新 UI;
- 方案 B(成本高): 宽档把播放条改成**右侧栏**(竖向: 封面 + 歌名 + 上下曲 + 进度)。
  需要新的竖向布局 + 断点内两套排布, 触碰 `player_bar.dart`(424 行, 已有窄/宽两套横向口径),
  golden 与 `player_bar_narrow_test` / `bottom_chrome_padding_test` 都要新增几何断言。
  **触发条件**: 用户明确要求桌面/平板上有独立播放器面板时再做, 且要先定竖向面板的宽度档。

### 4.2 二级页分栏 / 内嵌 detail pane(未实施)

现状: 28 处 `Navigator.of(context).push` 全屏 push; 宽档下 840 的内容区被单个页面占满,
列表 → 详情要来回跳。

- 方案: 壳层维护一个 `detailPane` 槽位(类似 `playerBarSlot`), 宽档时布局 = `Row(rail, IndexedStack(列表), 1px 分隔, detail(≥ 720))`;
  页面侧只把「push」换成一个统一入口 `openDetail(context, builder)`:
  宽档 ⇒ 写入 detailPane; 窄中档 ⇒ 仍 `push`。
- **成本**: 28 处调用点各改一行 + 详情页自身要能「被内嵌」(它们大量依赖 AppBar/返回键/
  `pageDepth` 让位语义) + 返回键策略(`back_policy.dart`)要新增「先清 detail pane」一级 +
  golden 需新增宽档基准; 估 2~3 个批次。
- **触发条件**: 用户实际在桌面/平板上用「列表 ↔ 详情」来回跳并抱怨时; 或宽档 rail 稳定运行一段时间后。
- 中途低成本替代: 宽档 push 二级页时仍**保留 rail**(需要把 `pageDepth` 让位从「<= 1 才显示」
  放宽为「宽档恒显示」), 让导航不消失。这一条与 4.2 相互独立, 可单做。

### 4.3 横屏手机(700~900 宽 / 高 < 450)特殊处理(未实施)

现状: 900 宽以下一律按中档 —— 底部导航 80 + 播放条 ~90 = 170 纵向预算被吃掉, 高 400 时
内容区只剩 230。手机横屏(常见 780x360 ~ 900x420)正好落在这一档。

- 方案: 档位函数加一个**纵向**输入(`layoutTierFor(width, height)` 或新增 `bool isShortLandscape
  = width >= 700 && height < 450`), 命中时把导航改回 Rail(省纵向)、播放条改成迷你单行(高 ≤ 56)。
- **成本**: 中。要改 `layoutTierFor` 签名(现在的纯函数与 15 例单测跟着改) + 播放条新增
  「短横屏」排版档 + 3 个新几何断言。
- **触发条件**: 出现真机横屏用户反馈, 或桌面小窗(900x400)实测拥挤。当前宽档 `1000x420` 已验证
  不竖溢(`nav_rail_shell_test`), 但没有做省纵向的专门排版。

---

## 5. 已知风险 / 待复核

1. **MediaQuery 宽度 ≠ 页面实际宽度**(最重要)。壳层限宽是**布局**层面的, `MediaQuery.sizeOf(context).width`
   仍是最外层窗口宽。现存的宽度判据里, 有 4 处读 MediaQuery:
   `player_bar.dart:222`(>= 600 用宽屏留白, 宽档恒真, 符合预期)、`song_tile.dart:702`(< 340 窄行,
   限宽后 840 远大于 340, 符合预期)、`feed_media.dart:71` / `cover_art.dart:274` / `layout.dart:368`
   (只在约束无限时**回退**到 MediaQuery, 不触发)、`messages/private_chat.dart:300`(气泡 maxWidth
   0.72×窗口宽, 被子容器 clamp, 不会溢出)。⇒ 当前**全部无害**, 但新增「按屏宽算列数 / 算分栏」
   的代码必须改用 `LayoutBuilder` 的 `constraints.maxWidth`, 否则会在宽档算出偏大的宽度。
2. **AppBar / 全屏背景在宽档只占 840**。这是「整屏限宽」的预期形态(内容与顶栏同宽居中),
   但和桌面软件「顶栏通栏」的习惯不同; 若要顶栏通栏, 得把限宽下移到每个 Scaffold 的 body,
   成本 = 152 个页面级改动, 判定不做。
3. **播放条比内容区宽**(见 4.1): 宽档下播放条通栏 840+ 内侧留白仍按窗口宽算, 视觉上右侧控件
   离内容右边缘有偏移。属已知差异, 不值得为它重做播放器 UI。
4. **Rail 判据用 MediaQuery, 内容限宽用 LayoutBuilder**: 两者在正常窗口下等值(Overlay 铺满窗口);
   若有朝一日把 `PlayerBarHost` 塞进更窄的容器, 二者会分叉 —— 届时 rail 判据也要换成
   壳层 `LayoutBuilder` 并回传档位(需要一个 `ValueNotifier<LayoutTier>` 槽位, 本次刻意不做)。
5. **键盘让位**: 宽档 Rail 在键盘弹出时与底部导航一样隐藏(`keyboardUp`) —— 保持「内容不被白压一条」
   的既有口径; 若要「键盘弹出仍保留 Rail」, 改 `_buildBottomBar` 的返回条件即可, 但要重跑
   `bottom_chrome_padding_test` 的键盘用例。
6. **没有宽档 golden**。现有 18 张全是窄视口, 所以本次壳层改动 **零 golden 重出**; 代价是
   宽档视觉回归没锁。建议后续补 2 张(1280x800 的 recommend / playlist_detail), 前提是先有
   「宽档基准」共识(否则每次调 kContentMaxWidth 都要重出)。
