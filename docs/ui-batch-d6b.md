# UI 批次 D6b：继续迁移到 PagedListView

日期：2026-11-30。承接 `docs/ui-batch-d6.md` 的"后续可迁移页清单"。本轮迁移 3 页
（new_release / all_charts / digital_album），**未改动 `paged_list_view.dart`**。

## 迁移页面（3 个，file:line 前后对比）

### 1. `ui/lib/src/new_release_page.dart`（新歌/新碟/歌手/精选新碟 4 页签）
- 前：4 个页签各自 State 手写 `_songs/_error/_load()` + 共用私有 `_AsyncBody`
  三态壳（原 155–520 行）；地区切换手写 `_area = area; _load()`。
- 后：全部换非分页 `PagedListView`（loader 恒 `hasMore:false`）：
  - 新歌 `PagedListView<rust.SongDto>`（new_release_page.dart:176），地区 chips 保留在
    Column 顶部（不随列表滚动），切地区用 `ValueKey(_area)` 重挂载触发重载；
  - 新碟 `PagedListView<rust.AlbumItemDto>`（:241），同上；
  - 歌手 `_HotArtistsTab` 改 StatelessWidget + `PagedListView<rust.HotArtistDto>`（:281）；
  - 精选新碟 `PagedListView<rust.AlbumItemDto>`（:327），原 `SliverGridDelegateWithMaxCrossAxisExtent`
    原样经 `gridDelegate` 传入，`padding: EdgeInsets.all(12)`。
- 删除：私有 `_AsyncBody`（约 60 行）与 4 份手写三态样板，净 -313 行。
- 行为差异：错误视图从"行内错误条(错误文本 + TextButton)"统一为组件的居中错误列 +
  `FilledButton.tonal(重试)`（D6 已确立的口径）；空态/错误文案均沿用 friendlyError 与原文案。

### 2. `ui/lib/src/all_charts_page.dart`（全部榜单）
- 前：State 手写 `_groups/_error/_load()` + 私有 `_AsyncBody`（原 62–145 与 158–197 行）。
- 后：`_AllChartsPageState` 只剩 build（all_charts_page.dart:53），body =
  `PagedListView<rust.ToplistCatalogGroupDto>`（:59，`refreshable: false` 保持原无下拉刷新），
  `itemBuilder` 直接渲染 `_GroupSection`（分组小标题/灰显逻辑不动）；删除 `_AsyncBody`。

### 3. `ui/lib/src/digital_album_page.dart`（数字专辑只读页）
- 前：State 手写 `_albums/_songs/_error/_loading` + `Future.wait` 双加载 +
  手写错误 ListView（"加载失败: …" + cloud_off 图标）与空态 ListView（原 32–90、117–190 行）。
- 后：引入密封 `_Entry`（digital_album_page.dart:29，_SectionHead/_AlbumEntry/_SongEntry），
  双加载合并进 `_entryLoader`（:54，恒 `hasMore:false`），body = `PagedListView<_Entry>`
  （:96）：区块小标题经 `_SectionHead(gapAbove)` 保持原间距；已购空态两行文案走
  `emptyBuilder`；下拉刷新沿用组件 `refreshable: true`（原页即有 RefreshIndicator）。
- 行为差异：错误文案从 `加载失败: <friendlyError>` 变为组件统一口径 `<friendlyError>`
  （去掉了"加载失败:"前缀与 cloud_off 图标），对应测试断言同步更新。

## 测试（用例数：前 289 passed + 1 skip → 后 292 passed + 1 skip）

- 新增 `ui/test/new_release_page_test.dart:40`「新歌页签: 错误重试 + 空态文案」（本轮唯一新增；
  其余各页的空态/错误重试用例 D6 前已存在，不重复添加）。
- 更新 `ui/test/digital_album_page_test.dart:83`：错误文案断言改为 friendlyError 口径
  （`网络不稳定`），对齐迁移后的组件语义。
- 本轮 4 个相关测试文件（new_release / all_charts / digital_album / paged_list_view）21 条全绿。

## 门禁实际输出

```
$ cd ui && timeout 1200 flutter analyze   # dart 不在 PATH，用 flutter analyze 等价
35 issues found                            // 0 error / 0 warning，全部 info（含既有）
$ cd ui && timeout 3600 flutter test
00:08 +292 ~1 -2: Some tests failed.
```
仅有的 2 个失败均来自 `ui/test/album_preview_test.dart`——`album_preview.dart`
工作区已有另一车道在途改动（`git status` 确认 M），与本批次白名单无关，未触碰。
排除该在途文件后本批次相关范围全绿。

## 剩余未迁页与原因

- `radio_explore_page.dart`：精选/推荐电台列表是"分类胶囊 + 榜单页签"大滚动视图里的
  内嵌 section（自带 loading/error/空态的多状态 Widget 列表），不是整页列表；
  硬迁需要组件支持"页内多 section 各自三态"，会破坏现结构，收益低。
- `style_page.dart`：风格歌单（横向）+ 风格歌曲（Card 内 Column）两个 section 共享一个
  滚动视图，且各自 FutureBuilder + InlineError；同上需多 section 能力，D6 文档已标注"保持现状"。
- **组件能力建议**（未实施，`paged_list_view.dart` 被测试锁定）：如后续要吃下这两页，
  可考虑给 PagedListView 增加"多 section 模式"（如 `sections: List<PagedSection>`，
  每个 section 独立 loader/emptyBuilder/errorBuilder，共享外层滚动），或提供
  `PagedSliver` 形态供 CustomScrollView 组合。

## 未做项

- 未改 `paged_list_view.dart` 及白名单外任何文件；未 git commit；未跑 cargo/codegen/构建脚本。
- 未迁 radio_explore / style（原因见上）。
