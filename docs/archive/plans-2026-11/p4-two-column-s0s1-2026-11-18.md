# P4 · 横屏双列 S0 + S1(方案 A 第一刀: 歌单详情)

日期: 2026-11-18 · 基线 v0.23.0(Dart 1205 / analyze 0 / 全量全绿)
方案来源: `docs/archive/plans-2026-11/wide-two-column-eval-2026-11-18.md` §2 方案 A、§3 S0/S1
范围: **只做 S0 + S1**。S2(播客详情复用)/S3(我的页打包双列)/S4(壳层主从)不做。
不 commit; 未改 `docs/PROGRESS.md`、`docs/remaining-batches.md`。

## 0 结论先行(数字)

| 项 | 结果 |
|---|---|
| 双列判据 | `宽 >= 900 且 高 >= 560`(`twoColumnFor(Size)`), 900x560 取等为真 |
| 双列几何 | 左 300 / 间距 12 / 右 528(正好填满既有 840 内容限宽), 无需放宽壳层 |
| 单列分支 | **零改动**: 同一棵 sliver 树、同一顺序 ⇒ 两张既有 golden 逐像素不变(已验) |
| 新增测试 | 9(+1)纯单测 + 6 条 getRect + 1 张 1280x720 golden = 全量 1205 → **1221 全绿** |
| 门禁 | `dart analyze` 0 issue(本人 4 文件) · check-tokens --strict OK · check-row-padding --strict OK |
| 未触碰 | 路由 / pageDepth / 返回键 / dismissAllPopups / 数据请求 / 交互 / feed / player_bar / settings_* / desktop_shell |

## 1 S0 · 判据纯函数(`ui/lib/src/layout.dart`)

新增 4 个常量 + 1 个纯函数(放在「布局档位」小节 `layoutTierFor` 之后):

- `kTwoColumnMinWidth = 900`(沿用 `kWideMinWidth` 的数字, 不造第四个宽度阈值)
- `kTwoColumnMinHeight = 560`
- `kTwoColumnListWidth = 300`
- `kTwoColumnGap = 12`(与 `kPagePadding` 同值但具名独立: 是栅格切分间距)
- `bool twoColumnFor(Size size)`: 宽高同时达标才双列; 无限宽/无限高视为**满足**该维度,
  NaN 一律 false(与 `layoutTierFor` 的非有限值口径一致)。

`layoutTierFor` 签名/语义未动。「全仓宽度阈值只有本节常量 + kPlayerBarRoomyWidth」那条注释
同步补上双列阈值, 避免留下过时断言。

测试: `ui/test/two_column_breakpoints_test.dart`(8 个锁死口径 + 1 条常量关系)
1280x720 T / 900x560 T / 899x720 F / 900x559 F / 780x360 F / 1920x1080 T / 840x800 F /
∞ 与 NaN 保守口径(F) / 300+12+528 == 840 且 kTwoColumnMinWidth == kWideMinWidth。

## 2 S1 · 歌单详情双列(`ui/lib/src/detail/playlist_detail_page.dart`)

`build` 的 body 二分成 `_buildSingleColumnBody` / `_buildTwoColumnBody`;

- 单列 = 改造前的 sliver 顺序原样: 头部卡 → 编辑横幅 → 筛选条 → 无版权提示 → 曲目 → 评论 → 底部 24。
- 双列 = `Row(stretch)`[`SizedBox(300, ListView(头部卡))`, `SizedBox(12)`, `Expanded(CustomScrollView)`],
  右列 = 编辑横幅 → 筛选条 → 无版权提示 → 曲目 → 评论 → 底部 24。
- 左栏 key `playlist-detail-info-column`, 右栏 key `playlist-detail-songs-column`(供 getRect)。

**滚动口径: 两列各自滚动。** 理由:
1. 头部卡在 300 宽下高度随简介展开 / 系统字号变化, 与曲目列表没有同步滚动语义;
   绑在一起会让「定位正在播放」把左栏一起滚出视野。
2. 右列继续用 `_scroll` ⇒ `_locateCurrent` 的「量曲目列表起点」语义原样成立;
   左栏不设 controller, 两列互不影响。
3. 左栏内容比右栏短时右栏仍能滚满 body 高度。

### 2.1 与评估文档的两处显式偏差(都有硬理由)

1. **判据入参用 `MediaQuery.sizeOf(context)`(窗口逻辑尺寸), 不是 LayoutBuilder 实测宽。**
   评估文档写的是「只用 LayoutBuilder 的实测宽」, 但壳层 `ContentWidthLimit` 把 body 限到
   840: 拿 840 比 900 **永远为假**, 双列会成死代码。窗口 >= 900 时 body 恰好 840 = 300+12+528,
   两栏不挤压 —— 所以 900 这个界的含义本就是窗口宽。已在代码注释里写明。
2. **编辑横幅 / 无版权提示放在右列**(评估文档 §S1 写的是放左列)。
   两块都是「这段曲目列表的说明」, 紧挨列表更自洽; 且窄档相对顺序(横幅→筛选→提示→曲目)
   在右列原样保留。左列只放**歌单信息**(封面/标题/创建者/统计/标签/简介)。

## 3 测试

### 3.1 几何(`ui/test/playlist_detail_two_column_test.dart`, 6 例)

用真实壳层的 `ContentWidthLimit` 包住 Navigator(与线上一致), 经 `showPlaylistDetail` push 出页面:

1. 1280x720: 左栏 `left == (1280-840)/2 == 220`、`width == 300`; 间距 `== 12`;
   右栏 `width == 528`、`right == 220+840`。
2. 1280x720: 两列 `top` 相同且 == AppBar 下沿; AppBar 仍整宽 840(不跟左栏缩)。
3. 840x800: 单列(- 只有 body 这一个 CustomScrollView), 矩形 `left 0 / width 840` 铺满。
4. 双向边界: 900x560 双列; 899x800 单列(宽差 1); 900x559 单列(高差 1)。
5. 780x360(手机横屏): 单列 ⇒ 高度判据生效。
6. 300x640 @1.25 字号: 单列、`width 300`、`takeException() == null`(不竖溢)。

### 3.2 golden(1 张, 只更这一张)

`ui/test/goldens/playlist_detail_1280x720.png`(1280x720 @1.0, 带 `ContentWidthLimit`)。
生成命令(只过滤这一条, 没有重出其余 18 张):

```
cd ui && flutter test test/golden_pages_test.dart --update-goldens --plain-name 'playlist_detail: 1280x720'
```

图内包含: 左侧 220..520(300 宽)只有歌单信息卡(封面 120 在卡片右缘 388..507 / 标题 /
创建者 / 「12 首 · 播放 128000 次」/ 华语·流行 标签 / 简介); 右侧 532..1060(528 宽)=
筛选条 + 曲目行(第 1 行正在播放带底色高亮, 其余「序号 歌名 / 艺人 · 专辑 / 04:29 + 红心」),
顶部 AppBar 通栏 840; 两侧 0..220 与 1060..1280 是壳层留白(通栏同色)。
以后动 `kContentMaxWidth` / `kTwoColumnListWidth` / `kTwoColumnGap` 都要重出这一张。

golden 变化逐张说明: **新增 1 张**; 既有 `playlist_detail_360x800.png` 与
`playlist_detail_300x640_s125.png` **无变化**(单独跑这两条用例通过, 证明单列分支逐像素一致);
其余 16 张未运行改动路径, 全量跑下来也全绿。

## 4 自验(全部实测)

- `dart analyze`(layout.dart / playlist_detail_page.dart / 两个新测试 / golden_pages_test.dart):
  **No issues found**。
- 目标测试: 15 例全绿(9 + 6)。
- 全量 `flutter test --exclude-tags network`: **0 失败**。
  · 干净基线 worktree(`/tmp/p4w`, HEAD v0.23.0 + 本次 5 文件): 1205 → **1221 passed / 0 failed**;
  · 主工作树(叠加别的车道在飞的改动): **1243 passed / 0 failed**。
  · 本次新增 16 例 = 9 纯单测 + 6 几何 + 1 golden。
- `tools/check-tokens.sh --strict` OK; `tools/check-row-padding.sh --strict` OK。

### 4.1 为什么在隔离 worktree 里跑的全量

本次运行期间工作树里有**别的车道**在并发写 `ui/lib/src/feed/*` 与 `ui/lib/src/artist_page.dart`:
一度 `ui/lib/src/feed/feed_merge.dart`(未跟踪文件)的 `import 'rust/api.dart'` 路径错误 +
`artist_page.dart` 括号未闭合 ⇒ 任何测试文件都编译不过(与本次改动无关)。
为不碰别人的文件、也不被别人的半成品阻塞, 全量先在 `git worktree add /tmp/p4w HEAD` 的
干净基线上 + 本次 5 个文件(2 源 / 2 测试 / 1 golden)复跑(1221 全绿); 之后对方修好
`feed_merge.dart` 的 import 与 `artist_page.dart` 的括号, 主工作树复跑也是 **1243 全绿**。
临时 worktree 已删除, 主工作树只留本次改动。

## 5 不做(边界)

S2 播客详情骨架复用 / S3 我的页打包双列 / S4 壳层主从分栏 —— 均未做。
未改 feed/、player_bar.dart、settings_*、desktop_shell.dart(别的车道路径)。
未 commit。
