# 列表行 / 溢出 只读审计（2026-11）

范围：`ui/lib/**`（排除 `ui/lib/src/rust/` codegen 产物）。只读审计，未改动 `lib/`、`test/`，未做任何 git 操作。

**行号基准：2026-11-13 20:43 的工作区快照。** 该仓库当时已有未提交改动（`git status` 显示 `ui/lib/main.dart`、`artist_page.dart`、`feed_view.dart`、`profile_banner.dart`、`user_page.dart`、`settings_view.dart` 等为 `M`），这些改动不是本审计产生的；若他人继续编辑，行号会漂移，请以表格里的锚点代码（如 `formatDurationMs(song.durationMs)`）重新定位。

## 0. 口径与证据

统计口径（命令可复现）：

```
$ rg -c '\bRow\(' ui/lib --glob '!src/rust/**' -g '*.dart' | awk -F: '{s+=$2} END{print s}'
107
$ rg -c '\bListTile\(' ... | awk ...            → 101（分布在 30 个文件）
$ rg -c 'AdaptiveText\(' ... | awk ...          → 22
$ bash tools/check-tokens.sh --top 200
check-tokens: OK(没有集合外的间距/圆角/字号)
$ cd ui && flutter test test/detail_song_row_narrow_test.dart test/narrow_width_audit_test.dart
00:02 +13: All tests passed!
```

从 107 处 `Row(` + 101 处 `ListTile(` 中筛出**列表行骨架 49 处（30 个文件）**：38 处由 `ListTile` 承载，11 处是手写 `Row(`（`detail_page:1193`、`artist_page:811`、`artist_sections:94`、`comment_thread:940`、`comment_thread:1083`、`feed_view:683`、`profile_banner:220`、`playlist_square_page:155`、`cover_quality_sheet:65`、`song_wiki:143`，另 1 处为 `main.dart` 的行内 `Row(` 组合）。

分级判据（本报告的判定标准，不达标即扣级）：

| 级别 | 判据 | 后果 |
|---|---|---|
| A | ① 行内可变长度文本是 `Row` 的直接 child，没有 `Expanded`/`Flexible`/`SizedBox(width:)`；② 行尾由 ≥2 个无宽度上限的组件叠加（默认尺寸 `IconButton`/`OutlinedButton` 等） | 抛 `RenderFlex overflow` 或把标题压到 0 宽 |
| B | 文本已有 `Expanded`/`Flexible`，但缺 `maxLines` + `overflow: ellipsis`（或只有 ellipsis 没有 maxLines ⇒ 会逐字换行） | 竖排 / 行高暴涨，不抛异常 |
| C | 行内 padding 不属于 `layout.dart` 的两级栅格（`kSongRowPadding` / `kCardRowPadding`），或同语义行在不同页面留白不同 | 同一 App 内左右留白跳变 |

一条判据细化：`mm:ss` 时长是 5 字符定长格式，把"时长缺宽度上限"判为 **B**（不是 A），否则全仓 7 处歌曲行会被误判成必坏。

## 1. 结论速览

| 级别 | 条数 | 涉及行 | 说明 |
|---|---|---|---|
| A 必坏 | **7** | 7 行 / 6 文件 | 其中 5 处**没有任何窄屏测试**兜底（见 §2「窄屏测试」列） |
| B 潜在 | **12** | 12 行 / 11 文件 | 缺 `maxLines`/`overflow` 或缺 trailing 上限；`digital_album_page` 4 处是"有 ellipsis 没 maxLines"的真换行 bug |
| C 一致性 | **18** | 18 行 / 17 文件 | 歌曲行存在 **6 种**行留白并存；另有 5 处 `contentPadding: EdgeInsets.zero` 直接贴容器边 |

## 2. A 级（必坏，7 条）

| # | 文件:行 | 行类型 | 缺什么 | 一句话原因 | 窄屏测试 |
|---|---|---|---|---|---|
| A1 | `comment_thread.dart:940`（offender: 986-989 `timeText`、995-998 `comment.ipLocation`） | 评论头行：头像+昵称+回复@+热门+时间+IP | 时间 / IP 是裸 `Text` | 昵称与「回复 @x」已是 `Flexible`，剩下的时间+IP 固定占宽，两者相加超宽时整行溢出 | 无 |
| A2 | `comment_thread.dart:1083`（动作行，含 1093/1128/1156） | 点赞 / 回复 / 删除 / 更多 动作行 | 整行无 flex，动作数量随 `onDelete != null` 变化 | 4 个动作 ×(图标 14+文字+padding 4/2)+3×10 间距，300dp×1.625 下必溢出，且行内没有 `Wrap` | 无 |
| A3 | `feed_view.dart:683`（offender: 704-705 `feedRelativeTime`） | 动态头行：头像+用户名+相对时间 | 相对时间裸 `Text` | 用户名 `Expanded` 会先被压到 0，随后时间（"刚刚"/"2026-11-09"宽度可变）继续撑破行 | `ui_batch_d_narrow_test`（300dp×1.25，仅此一档） |
| A4 | `profile_banner.dart:220`（offender: 298 `trailing!`） | 主页头行：头像+昵称+VIP+副标题+trailing | trailing 直接塞进 `Row`，无 `ConstrainedBox` | 外部传入的按钮宽度不受控，昵称区已有 `Flexible` ⇒ 空间不足时按钮被挤出屏幕 | 无 |
| A5 | `playlist_square_page.dart:155`（offender: 171 `'分类加载失败'`） | 分类快捷行：`热门`/`精品` chip + 错误文字 | 行内无滚动、无 flex | chip 数固定但错误文字裸排在 chip 之后，1.625 字号下 chip+文字 > 300dp，横向无处可去 | 无 |
| A6 | `detail_page.dart:1193`（offender: 1247-1268 trailing） | 歌单详情歌曲行（序号+歌名+徽标+歌手·专辑+时长+红心+更多） | 行尾三件（时长 `Text` + 默认尺寸 `IconButton` + `SongOverflowButton`）无 `ConstrainedBox` | 全仓最宽 trailing（约 130dp），标题区在 300dp 下只剩 ~117dp；trailing 宽度不由本行约束 | `detail_song_row_narrow_test`（300dp×1.25 三档徽标 + 400dp，**1.625 未覆盖**） |
| A7 | `play_queue_sheet.dart:254`（offender: 290-315 trailing） | 队列行：拖拽 handle / 序号 + 歌名 + 艺人 + 播放入口 | trailing 两个默认尺寸 `IconButton`（48+48）无上限 | `IconButton` 默认命中区 48dp，与 leading 序号列叠加后标题被压到个位数宽度 | `narrow_width_audit_test`（队列面板，300/320/360 × 1.0/1.25/1.3/1.625） |

## 3. B 级（潜在，12 条）

| # | 文件:行 | 缺什么 | 一句话原因 |
|---|---|---|---|
| B1 | `digital_album_page.dart:144` / `146` / `155` / `156` | `maxLines: 1` | 写了 `overflow: TextOverflow.ellipsis` 但没 `maxLines` ⇒ 先换行再省略，长专辑名逐字竖排（`song_tile.dart:233` 注释记录过同类实测 378px 行高） |
| B2 | `radio_subscribers_page.dart:93` | `maxLines: 1` | 同上：只有 ellipsis 没有 maxLines |
| B3 | `cover_quality_sheet.dart:81` / `88` | `maxLines` + `overflow` | `tier.label` / `tier.hint` 在 `Expanded` 内但完全不限行，hint 两行以上时 64dp 封面被撑高 |
| B4 | `song_wiki.dart:149` / `156` | `maxLines` + `overflow` | 键值行：`SizedBox(width: 72)` 的标签列 + `Expanded(value)` 无行数限制 |
| B5 | `song_tile.dart:240`（offender 245 时长 `Text`） | trailing 上限 | 两个 `IconButton` 已收到 40dp（`minWidth: 40`），但整行 trailing 仍无 `maxWidth`，时长文本随字号增长 |
| B6 | `artist_page.dart:811`（offender 847-848） | trailing 上限 | 时长裸 `Text` + `SongOverflowButton`（默认 48dp），无 `ConstrainedBox` |
| B7 | `artist_sections.dart:94`（offender 145） | trailing 上限 | 同上；且该行 pitch 用 `symmetric(vertical: 6)`，与同页其它行不同（见 C4） |
| B8 | `ranking_view.dart:253`（offender 289 `'${entry.playCount} 次'`） | trailing 上限 | `playCount` 位数可变（`1234567 次` ≈ 70dp），`ListTile.trailing` 不设上限 ⇒ 标题被压 |
| B9 | `mine_view.dart:411`（offender 427/432 `'共 N 首'`） | trailing 上限 | trailing 是 `Row(mainAxisSize.min)` 内嵌裸 `Text` + `SongOverflowButton` |
| B10 | `new_release_page.dart:191`（offender 200） | trailing 上限 | 新歌行 trailing 是裸 `Text`（发行日期），无 `ConstrainedBox` |
| B11 | `messages_page.dart:735`（offender 755-763） | trailing 上限 | 私信会话行 trailing `Row` 内相对时间裸 `Text`，宽度随 "3天前"/日期变化 |
| B12 | `user_list_page.dart:157`（offender 178 `OutlinedButton`） | trailing 上限 | 关注按钮用默认 `OutlinedButton`（左右 padding 各 16，宽约 72dp），无 `maxWidth` |

## 4. C 级（一致性，18 条）

### 4.1 同一个「歌曲行」有 6 种行留白（12 行）

| 留白 | 值 | 出现的行 |
|---|---|---|
| `kSongRowPadding` | 8 / 0 / 4 | `song_tile.dart:214`、`recommend_view.dart:329`、`recommend_view.dart:651`、`ranking_view.dart:257`（经 `padding` 参数） |
| `kCardRowPadding` | 4 / 0 / 4 | `mine_view.dart:415`、`mine_view.dart:678` |
| 自造 `fromLTRB(12, 0, 4, 0)` | 12 / 0 / 4 | `detail_page.dart:1192` |
| 自造 `symmetric(horizontal: 12, vertical: 8)` | 12 / 8 | `artist_page.dart:810` |
| 自造 `symmetric(vertical: 6)` | 0 / 6 | `artist_sections.dart:93` |
| 不设（Material 默认 16/16） | 16 / 16 | `discover.dart:661`、`album_preview.dart:362`、`similar_sheet.dart:147`、`style_page.dart:282`、`all_charts_page.dart:100`、`new_release_page.dart:191`、`play_queue_sheet.dart:254`、`my_collections_page.dart:109` |

### 4.2 `contentPadding: EdgeInsets.zero`（5 行，贴容器边）

| 文件:行 | 说明 |
|---|---|
| `radio_explore_page.dart:350`、`468`、`487`、`516` | 电台/节目/榜单/主播四种行全部 0 留白，与同页标题的 `kPagePadding(12)` 不共线 |
| `radio_subscribers_page.dart:146` | 同上 |

### 4.3 自造第四种 padding（1 行）

| 文件:行 | 说明 |
|---|---|
| `comment_thread.dart:1306` | `fromLTRB(4, 0, 12, …)`：卡片内评论引用行，既不是 `kCardRowPadding` 也不是 `kSongRowPadding` |

### 4.4 说明

`check-tokens.sh` 当前 **0 越界**（数值都在白名单内），所以 C 级不是"数值非法"，而是"同一个语义用了不同的合法数值"。

## 5. 重复实现统计

| 骨架 | 出现次数 | 文件数 | 文件清单 |
|---|---|---|---|
| **歌曲行**：cover40 + 歌名(+徽标) + 歌手·专辑 + 时长/更多 | **16** | **14** | `song_tile.dart:210`、`detail_page.dart:1193`、`artist_page.dart:811`、`artist_sections.dart:94`、`discover.dart:661`、`recommend_view.dart:326`、`recommend_view.dart:648`、`mine_view.dart:411`、`mine_view.dart:674`、`play_queue_sheet.dart:254`、`album_preview.dart:362`、`similar_sheet.dart:147`、`style_page.dart:282`、`all_charts_page.dart:100`、`new_release_page.dart:191`、`ranking_view.dart:253` |
| **封面行**：cover48/52 + 标题 + 副标题 + chevron | **13** | **11** | `discover.dart:396/510/533/550`、`radio_explore_page.dart:349/467/486/515`、`radio_subscribers_page.dart:145`、`new_release_page.dart:246/279`、`my_collections_page.dart:109`、`digital_album_page.dart:142/153`、`artist_page.dart:779`、`search_suggest.dart:81`、`search_landing.dart:290` |
| **用户行**：头像 + 昵称 + 签名 + 可选按钮 | **6** | **5** | `user_list_page.dart:157`、`user_page.dart:402`、`radio_subscribers_page.dart:145`、`messages_page.dart:280/735/834`、`feed_view.dart:1125/1155` |
| **设置/入口行**：图标 + 标题 + 副标题 + 开关/下拉/chevron | **30** | **8** | `settings_view.dart`（19 处）、`settings_audio_page.dart`（5）、`settings_account_page.dart`（4）、`settings_diagnostics_page.dart`（3）、`mine_view.dart`（3）、`main.dart`（4）、`detail_page.dart`（2）、`song_actions.dart`（6，纯图标+文字） |

判断：**歌曲行值得收敛**——16 处里有 12 处的实现代码几乎逐行同构（cover → gap → `Column(标题, 2 → 副标题)` → 时长 → overflow 按钮），且 `SongTile` 这个唯一共享组件只被 3 处使用（`rg -c 'SongTile\('` ⇒ `song_tile.dart`/`search_results.dart`/`main.dart`）。
封面行 / 用户行 / 设置行**不值得自造组件**：它们已经是 `ListTile`，`ListTile` 自己就处理了 flex 与 `horizontalTitleGap`，收敛价值只在 padding 一处（用 C 级清单统一即可）。

## 6. `ListRow` 最小 API 草案

给"手写 Row 的歌曲行"用（**不替换 `ListTile`**，`ListTile` 无法约束 trailing 宽度，这正是 A6/A7 的成因）。

```dart
/// 列表行骨架（歌曲/封面/用户通用的横向三段：leading + 文本列 + trailing）。
/// 为什么不用 ListTile：ListTile 给 trailing 的是松约束，行尾放两个 48dp IconButton
/// 时标题会被压到 0 宽（detail_page:1193 / play_queue_sheet:254 的溢出根因）。
class ListRow extends StatelessWidget {
  const ListRow({
    super.key,
    required this.title,          // 调用方给 Text / AdaptiveText / SongTitleWithBadges
    this.leading,                 // 封面 / 头像 / 序号 / 播放中图标
    this.subtitle,
    this.trailing,
    this.onTap,
    this.contentPadding = kSongRowPadding,
    this.trailingMinWidth = 40,   // 行尾最少槽宽: 让「时长」「更多」列在各页对齐
    this.trailingMaxRatio = 0.42, // 行尾最多吃 42% 宽, 与 section_header 的 60% 同思路
  });
}
```

实现要点（3~5 步）：

1. `InkWell` → `Padding(contentPadding)` → `Row(crossAxisAlignment: center)`：`[leading?, SizedBox(kRowTitleGap), Expanded(Column(title, subtitle?)), SizedBox(kRowTitleGap), ???]`。
2. `LayoutBuilder` 取可用宽，`trailingMaxWidth = maxWidth * trailingMaxRatio`；`trailing` 非空时包 `ConstrainedBox(constraints: BoxConstraints(minWidth: trailingMinWidth, maxWidth: trailingMaxWidth))`。
3. `title` / `subtitle` 由调用方负责 `maxLines`+`overflow`（组件不猜文案语义；跑马灯仍走 `AdaptiveText`）。
4. 行高只给 `ConstrainedBox(minHeight: 56)`，不写死 `itemExtent`——现有 `SliverFixedExtentList(itemExtent: _kRowHeight)` 的调用点保留。
5. 徽标不内建：继续用 `SongTitleWithBadges` / `SongFeeBadges` 组合（`Expanded` 在组件内，天然不吃 trailing 宽度）。

## 7. 改造顺序（按「A 条数 / 改动行数」降序，10 条内）

| # | 目标 | 覆盖 A/B 条 | 涉及文件:行 | 预估改动行数 |
|---|---|---|---|---|
| 1 | 行尾收口：`ConstrainedBox(maxWidth)` 包 trailing，两个默认 `IconButton` 收到 40dp（`shrinkWrap` + `constraints`，照 `song_tile.dart:251` 写法） | A6、A7 | `detail_page.dart:1247-1268`、`play_queue_sheet.dart:290-315` | ~25 |
| 2 | 评论头行：`timeText`、`ipLocation` 各包 `Flexible`（或整行改 `Wrap`） | A1 | `comment_thread.dart:986-999` | ~6 |
| 3 | 评论动作行：`Row` → `Wrap(spacing: 10, crossAxisAlignment: center)` | A2 | `comment_thread.dart:1083-1170` | ~4 |
| 4 | 动态头行：相对时间包 `Flexible` | A3 | `feed_view.dart:704-709` | ~3 |
| 5 | 主页头 trailing 包 `ConstrainedBox(maxWidth: 40% 可用宽)` | A4 | `profile_banner.dart:296-299` | ~6 |
| 6 | 分类快捷行改横向滚动：`Row` → `SingleChildScrollView(scrollDirection: horizontal, child: Row)` | A5 | `playlist_square_page.dart:155-177` | ~3 |
| 7 | 落地 `ListRow`（§6），先迁 4 个手写歌曲行验证形态 | B5/B6/B7 + 后续统一 | 新增 `ui/lib/src/list_row.dart`；`song_tile.dart`、`detail_page.dart:1193`、`artist_page.dart:811`、`artist_sections.dart:94` | ~120（新增 60 + 迁移 60） |
| 8 | 补齐 `maxLines: 1`（只有 ellipsis 没 maxLines 的 5 处） | B1、B2 | `digital_album_page.dart:144/146/155/156`、`radio_subscribers_page.dart:93` | ~6 |
| 9 | 文本列补 `maxLines`+`overflow` | B3、B4 | `cover_quality_sheet.dart:81/88`、`song_wiki.dart:149/156` | ~8 |
| 10 | padding 归一：默认 16/16 的 8 处歌曲行改 `kSongRowPadding`，`EdgeInsets.zero` 的 5 处补 `kPageHorizontalPadding` 对齐 | C1、C2 | 见 §4.1、§4.2 清单（13 行） | ~13 |

建议动手顺序就是表里 1→10：前 6 条是纯局部改动（合计 ~47 行）即可清掉全部 7 条 A；第 7 条是唯一"重构"，必须放在 A 清零之后，否则无法判断回归是重构还是修复引入的。每改一处，先把对应行加进 `ui/test/narrow_width_audit_test.dart` 的 12 组合矩阵（300/320/360 × 1.0/1.25/1.3/1.625），再改代码。

## 8. 不建议收敛成 `ListRow` 的例外

| 例外 | 文件:行 | 理由 |
|---|---|---|
| 可滑动删除的行 | `play_queue_sheet.dart:241`（`Dismissible` 包 `ListTile`） | `Dismissible` 需要稳定的子树 key 与整行 `onDismissed`，收敛后 handle/手势层会与外层 `InkWell` 抢事件 |
| 横向滚动的行组 | `playlist_square_page.dart:183`（横向 `ListView` 的 chip 组）、`style_page.dart:191`（118dp 卡片横向列表）、`ranking_view.dart:101` | 这些不是"一行一员"而是滚动容器，收敛会把滚动方向与 itemExtent 一并塞进 `ListRow` |
| 多行正文行 | `comment_thread.dart:871`（正文不限行）、`feed_view.dart:670`（正文 4 行 + 图片九宫格）、`album_preview.dart:240`（简介 3 行 + 收藏按钮） | 副标题行数由内容决定，`ListRow` 的"单行 + ellipsis"契约会截断正文 |
| 左右双列/仪表类行 | `settings_audio_page.dart:174`（title+subtitle+`DropdownButton`）、`vip_page.dart:616`（`Expanded` 列 + 进度条） | trailing 是交互控件而非"操作入口"，宽度由控件自身决定，加 `maxWidth` 反而会截断下拉菜单 |
| 已有统一组件且只差调用点 | `section_header.dart:68`（`SectionHeader`/`SectionTitle`）、`adaptive_text.dart:195`（`AdaptiveTextRow`） | 已有正确实现，问题是调用点没迁移，属"迁移任务"不属"新组件" |
