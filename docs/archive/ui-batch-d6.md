# UI 批次 D6：抽 `PagedListView` 公共组件

日期：2026-11-30。对应 `api-overlap-audit.md` 的 D6 条目（列表「分页 + 空态 + 错误重试」三件套在多页重复手写）。

## 组件 API 设计（`ui/lib/src/paged_list_view.dart`，纯 Dart，无 FFI/provider 依赖）

```dart
class PagedPage<T> {
  const PagedPage(this.items, {required this.hasMore, this.nextCursor});
  final List<T> items;
  final bool hasMore;      // 由调用方判定（常见: items.length >= pageSize）
  final int? nextCursor;   // 缺省 = cursor + items.length；去重页按“已消费行数”显式给
}

typedef PagedLoader<T> = Future<PagedPage<T>> Function(int cursor);
typedef PagedItemBuilder<T> = Widget Function(BuildContext, T item, int index, List<T> items);

class PagedListView<T> extends StatefulWidget {
  const PagedListView({
    required this.loader,          // loader(cursor) 闭包，重试/取数留给调用方（可注入）
    required this.itemBuilder,
    this.pageSize = 30,
    this.keyOf,                    // 去重键；null 不去重
    this.emptyText = '暂无内容',
    this.emptyBuilder,             // 自定义空态
    this.header,                   // 随滚动列表头（筛选条/联系人横滑条）
    this.separator,                // 条目分隔（线性模式）
    this.padding,
    this.gridDelegate,             // 传入则 SliverGrid 网格模式
    this.refreshable = true,       // 下拉刷新
    this.endText,                  // 到底提示；null 则无尾部件
    this.moreText = '加载更多',
    this.retryText = '重试',
    this.physics,
  });
}
```

三态行为：首屏 `CircularProgressIndicator` → 首屏失败居中错误视图（文案走 `friendlyError`）+ `FilledButton.tonal` 重试 → 空态（文案/自定义）→ 列表。
分页行为：`NotificationListener` 触底前 300px 自动预取 + 底部「加载更多」按钮兜底；加载更多失败保留旧数据、只弹 `SnackBar(friendlyError(e))`；`keyOf` 去重（同 key 不重复入列）。
非分页单次加载页面：loader 忽略 cursor、恒返回 `hasMore: false` 即可复用同一三态壳。

## 迁移页面（4 个，file:line 前后对比）

### 1. `ui/lib/src/user_list_page.dart`（关注/粉丝，offset 分页）
- 前：State 内手写 `_items/_loading/_loadingMore/_hasMore/_error` + `_reload/_loadMore/_buildFooter`（原 62–280 行，约 120 行样板）。
- 后：`PagedListView<UserItemDto>`（`user_list_page.dart:139`），loader 闭包包 `retryNetwork`、`nextCursor` 按已消费行数；空态两行文案走 `emptyBuilder`；关注/粉丝切换用 `ValueKey(_fans)` 重挂载触发重载。本地 `_followOverrides` 与关注/取关交互保持原样。

### 2. `ui/lib/src/messages_page.dart`（私信会话列表）
- 前：`_SessionsTabState` 手写分页 + 按 `userId` 去重 + `_MoreRow` 尾部件 + `NotificationListener` 触底预取（原 190–425 行）。
- 后：`PagedListView<PrivateSessionDto>`（`messages_page.dart:227`），`keyOf: (s) => s.userId` 去重、`nextCursor = cursor + page.length`、`endText: '没有更多了'`、`separator: Divider(indent: 68)`、`header: _ContactsStrip`（联系人横滑条仍在 tab 态自管）。删除了页面私有的 `_MoreRow`（约 45 行）。行为差异：加载更多失败从“整页错误条”统一为组件语义（SnackBar + 保留旧数据）。

### 3. `ui/lib/src/playlist_square_page.dart`（歌单广场，网格）
- 前：`CustomScrollView` 内手写 tri-state slivers + `SliverGrid` + `_buildFooter` + `_reload/_loadMore`（原 104–243 行）。
- 后：`PagedListView<PlaylistDto>`（`playlist_square_page.dart:129`），`gridDelegate` 网格模式、`header: _buildFilterBar`（分类筛选条原样保留）、`ValueKey('$_highQuality|$_cat')` 切分类/精品重挂载；精品歌单 loader 恒 `hasMore:false` 不分页。分类条/卡片/回调全部不动。

### 4. `ui/lib/src/ranking_view.dart`（听歌排行整页模式）
- 前：整页模式 `FutureBuilder` 手写三态 + 空态文案 + 错误视图（原 build 114–232 行）。
- 后：整页模式走 `PagedListView<PlayRankEntryDto>`（`ranking_view.dart:133`，`refreshable:false`，`emptyBuilder` 保留原空态文案）；compact 内嵌模式仍用原 `FutureBuilder`（行内错误条，不撑坏父布局）。`_future` 仅 compact 时加载，避免整页模式双重取数。

## 新增用例（`ui/test/paged_list_view_test.dart`，8 条）

1. 首屏加载：先骨架后数据；2. 首屏错误：friendlyError + 重试后成功；3. 空态：默认文案与自定义 emptyBuilder；4. 触底自动加载下一页 + cursor 递增透传；5. 加载更多失败：保留旧数据 + SnackBar；6. 去重：同 key 不重复入列 + nextCursor 按已消费行数推进；7. 300dp + textScale 1.25 不溢出（数据 + 到底提示）；8. 网格模式 + 列表头 + 下拉刷新。

## 全量测试实际输出

```
$ cd ui && timeout 3600 flutter test
...
00:06 +242 ~1: All tests passed!
```

242 通过 / 1 跳过（既有 skip）。基线 235，净增 7（新增 8 条组件用例，playlist_square「加载更多按 offset 追加」按新的触底自动加载语义改写断言：手动 tap 改为验证连续自动预取 [0,30,60,90,120]，删除了依赖视口内 footer 按钮的可见性断言）。

```
$ cd ui && timeout 1200 dart analyze
32 issues found   // 0 error，全部为既有 info/warning
```

## 后续可迁移的页（按契合度排序）

- `new_release_page.dart` / `all_charts_page.dart`：各自私有的 `_AsyncBody` 三态壳可换成非分页 `PagedListView`（loader 恒 `hasMore:false`），一次性消掉两份重复实现；错误视图从行内条变为居中列，需接受轻微视觉变化。
- `radio_explore_page.dart`：『暂无精选电台/该分类暂无推荐电台/该榜单暂无数据』等多处空态可收进 emptyText。
- `digital_album_page.dart`：已购专辑/单曲两个单次加载列表。
- `messages_page.dart` 其余页签（通知/评论/@我）：单次加载，非分页模式即可。
- `style_page.dart`：两个 section 在同一滚动视图内，需组件支持多 section 或保持现状。
- `artist_page.dart` / `album_preview.dart`：结构较杂（头部 + 多 section），收益低。

## 未做项

- 未迁移 new_release/all_charts/radio_explore/digital_album 等（已迁 4 页达到下限，避免本轮改动面过大）。
- 未 git commit；未跑 cargo/codegen/构建脚本（遵守车道隔离）。
- `ui/lib/src/song_tile.dart` 的工作区改动来自其他车道，本批次未触碰。
